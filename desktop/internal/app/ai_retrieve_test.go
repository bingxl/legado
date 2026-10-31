package app

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ── 辅助 ────────────────────────────────────────────────────────

// seedChunks 写入若干切片，vecs 与之一一对应（nil 表示该片没有向量）。
func seedChunks(t *testing.T, repo *fakeChunkRepo, bookID int64, texts []string, vecs [][]float32) []*domain.AIChunk {
	t.Helper()
	batch := make([]*domain.AIChunk, len(texts))
	for i, s := range texts {
		batch[i] = &domain.AIChunk{
			BookID:     bookID,
			ChapterIdx: i,
			Ordinal:    i,
			Title:      fmt.Sprintf("第%d章", i+1),
			Text:       s,
			TokenCount: estimateTokens(s),
			SrcHash:    textHash(s),
		}
	}
	if err := repo.PutBulk(context.Background(), batch); err != nil {
		t.Fatalf("写入切片失败: %v", err)
	}
	stored, err := repo.List(context.Background(), bookID)
	if err != nil {
		t.Fatalf("读取切片失败: %v", err)
	}
	for i, v := range vecs {
		if i >= len(stored) || v == nil {
			continue
		}
		if err := repo.UpdateEmbedding(context.Background(), stored[i].ID, v, "test-embed", len(v)); err != nil {
			t.Fatalf("写入向量失败: %v", err)
		}
	}
	stored, err = repo.List(context.Background(), bookID)
	if err != nil {
		t.Fatalf("读取切片失败: %v", err)
	}
	return stored
}

// newRecallService 只装配召回用到的最小依赖。
func newRecallService(chunks *fakeChunkRepo, llm *fakeLLM) *AIService {
	if chunks == nil {
		chunks = newFakeChunkRepo()
	}
	return NewAIService(AIDeps{LLM: llm, Chunks: chunks})
}

// ── 关键词切分 ──────────────────────────────────────────────────

func TestAIBigrams(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []string
	}{
		{name: "纯中文取二元组", in: "金属切削", want: []string{"金属", "属切", "切削"}},
		{name: "单字保留", in: "刀", want: []string{"刀"}},
		{name: "英文整词并小写", in: "OpenCV 应用", want: []string{"opencv", "应用"}},
		{name: "中英相邻要断开", in: "iPad保护壳", want: []string{"ipad", "保护", "护壳"}},
		{name: "数字与中文断开", in: "第2章", want: []string{"第", "2", "章"}},
		{name: "空串无词", in: "", want: nil},
		{name: "纯标点无词", in: "，。！？--", want: nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := aiBigrams(c.in)
			if strings.Join(got, "|") != strings.Join(c.want, "|") {
				t.Fatalf("切分不符，期望 %q，实际 %q", c.want, got)
			}
		})
	}
}

// 查询词要去重：重复的词会人为放大它在打分里的权重。
func TestAITermsDedupe(t *testing.T) {
	// 「刀具刀具」的二元组是 刀具/具刀/刀具/具刀，去重后剩两个。
	terms := aiTerms("刀具刀具")
	if strings.Join(terms, "|") != "刀具|具刀" {
		t.Fatalf("去重结果不符: %q", terms)
	}
	seen := map[string]bool{}
	for _, term := range terms {
		if seen[term] {
			t.Fatalf("出现重复词 %q", term)
		}
		seen[term] = true
	}
}

// ── 关键词打分 ──────────────────────────────────────────────────

// 只在少数切片出现的词，权重必须高于到处都有的词。
func TestKeywordScoresRankRareTerm(t *testing.T) {
	chunks := []*domain.AIChunk{
		{ID: 1, Text: "量子纠缠是一种物理现象"},
		{ID: 2, Text: "今天天气不错适合出门"},
		{ID: 3, Text: "量子力学的历史"},
	}
	scores := keywordScores(aiTerms("纠缠"), chunks)

	if scores[2] != 0 || scores[3] != 0 {
		t.Fatalf("不相关的切片不该得分: %v", scores)
	}
	if scores[1] != 1 {
		t.Fatalf("唯一命中的切片应被归一到 1，实际 %v", scores[1])
	}
}

func TestKeywordScoresNoOverlap(t *testing.T) {
	chunks := []*domain.AIChunk{{ID: 1, Text: "今天天气不错"}}
	if got := keywordScores(aiTerms("量子纠缠"), chunks); len(got) != 0 {
		t.Fatalf("完全不相关时不应有分数: %v", got)
	}
}

// 空查询词（比如用户只输入标点）不能把全部切片都打成 0 分之外的东西。
func TestKeywordScoresEmptyTerms(t *testing.T) {
	chunks := []*domain.AIChunk{{ID: 1, Text: "今天天气不错"}}
	if got := keywordScores(nil, chunks); len(got) != 0 {
		t.Fatalf("空查询不应有分数: %v", got)
	}
}

// ── 混合召回 ────────────────────────────────────────────────────

// 向量路正常时，语义最接近的切片必须排第一。
func TestRecallVectorRanking(t *testing.T) {
	repo := newFakeChunkRepo()
	// 三片向量两两正交，查询向量与第一片同向。
	seedChunks(t, repo, 1, []string{"甲内容", "乙内容", "丙内容"}, [][]float32{
		{1, 0}, {0, 1}, {0, 0, 1},
	})
	llm := &fakeLLM{embedFunc: func([]string) [][]float32 { return [][]float32{{1, 0}} }}
	svc := newRecallService(repo, llm)

	res := svc.recall(context.Background(), embedAIConfig(), 1, "随便问问", 3)
	if !res.UsedVector {
		t.Fatalf("应使用向量通道: %+v", res)
	}
	if len(res.Hits) == 0 {
		t.Fatal("应有召回结果")
	}
	if res.Hits[0].Chunk.Ordinal != 0 {
		t.Fatalf("最相似的应是第 1 片，实际第 %d 片", res.Hits[0].Chunk.Ordinal+1)
	}
	if res.Hits[0].Vector <= res.Hits[1].Vector {
		t.Fatalf("向量分未体现相似度: %+v", res.Hits)
	}
}

// 向量服务挂掉时不能拦住提问：降级 + 说明原因。
func TestRecallDegradesWhenEmbedFails(t *testing.T) {
	repo := newFakeChunkRepo()
	seedChunks(t, repo, 1, []string{"量子纠缠的物理机制", "今天天气不错"}, [][]float32{{1, 0}, {0, 1}})
	llm := &fakeLLM{embedErr: errors.New("embedding 服务 404")}
	svc := newRecallService(repo, llm)

	res := svc.recall(context.Background(), embedAIConfig(), 1, "量子纠缠", 5)
	if res.UsedVector {
		t.Fatal("向量失败时不应标记为已使用向量")
	}
	if !strings.Contains(res.Note, "关键词") {
		t.Fatalf("应说明已降级为关键词匹配，实际 %q", res.Note)
	}
	if len(res.Hits) == 0 {
		t.Fatal("降级后仍应有关键词召回结果")
	}
	if res.Hits[0].Chunk.Ordinal != 0 {
		t.Fatalf("关键词命中的应是第 1 片，实际第 %d 片", res.Hits[0].Chunk.Ordinal+1)
	}
}

// 没配向量模型（DeepSeek 这类）时安静降级，不报错。
func TestRecallWithoutEmbeddingConfig(t *testing.T) {
	repo := newFakeChunkRepo()
	seedChunks(t, repo, 1, []string{"刀具磨损与寿命", "无关内容"}, nil)
	svc := newRecallService(repo, &fakeLLM{})

	res := svc.recall(context.Background(), simpleAIConfig(), 1, "刀具磨损", 5)
	if res.UsedVector {
		t.Fatal("未配置向量模型时不应使用向量通道")
	}
	if !strings.Contains(res.Note, "未配置向量模型") {
		t.Fatalf("应说明未配置向量模型，实际 %q", res.Note)
	}
	if len(res.Hits) == 0 {
		t.Fatal("应有关键词召回结果")
	}
}

// 两路都召回同一片时只能出现一次，且分数取融合值而不是相加。
func TestRecallDedupesChunks(t *testing.T) {
	repo := newFakeChunkRepo()
	seedChunks(t, repo, 1, []string{"量子纠缠的物理机制", "天气不错"}, [][]float32{{1, 0}, {0, 1}})
	llm := &fakeLLM{embedFunc: func([]string) [][]float32 { return [][]float32{{1, 0}} }}
	svc := newRecallService(repo, llm)

	res := svc.recall(context.Background(), embedAIConfig(), 1, "量子纠缠", 10)
	seen := map[int64]int{}
	for _, h := range res.Hits {
		seen[h.Chunk.ID]++
	}
	for id, n := range seen {
		if n > 1 {
			t.Fatalf("切片 %d 重复出现 %d 次", id, n)
		}
	}
	if len(res.Hits) == 0 {
		t.Fatal("应有召回结果")
	}
	if res.Hits[0].Score > 1 {
		t.Fatalf("融合分数应在 0~1：%v", res.Hits[0].Score)
	}
}

// 没有索引时给出可读原因，而不是空结果让上层猜。
func TestRecallWithoutIndex(t *testing.T) {
	svc := newRecallService(nil, &fakeLLM{})
	res := svc.recall(context.Background(), simpleAIConfig(), 1, "随便问问", 5)
	if len(res.Hits) != 0 {
		t.Fatalf("空索引不该有召回: %+v", res.Hits)
	}
	if !strings.Contains(res.Note, "还没有建立索引") {
		t.Fatalf("应提示尚未建立索引，实际 %q", res.Note)
	}
}

// 召回条数受 topK 约束。
func TestRecallTopK(t *testing.T) {
	repo := newFakeChunkRepo()
	texts := make([]string, 20)
	vecs := make([][]float32, 20)
	for i := range texts {
		texts[i] = fmt.Sprintf("第%d段 刀具 内容", i)
		vecs[i] = []float32{1, 0}
	}
	seedChunks(t, repo, 1, texts, vecs)
	llm := &fakeLLM{embedFunc: func([]string) [][]float32 { return [][]float32{{1, 0}} }}
	svc := newRecallService(repo, llm)

	res := svc.recall(context.Background(), embedAIConfig(), 1, "刀具", 4)
	if len(res.Hits) > 4 {
		t.Fatalf("召回条数应不超过 topK=4，实际 %d", len(res.Hits))
	}
}

// ── 上下文装配 ──────────────────────────────────────────────────

func TestAIContextWindow(t *testing.T) {
	cases := []struct {
		name string
		cfg  *domain.AIConfig
		want int
	}{
		{name: "显式填写优先", cfg: &domain.AIConfig{ContextWindow: 5000, Model: "gpt-4o"}, want: 5000},
		{name: "128k 档", cfg: &domain.AIConfig{Model: "gpt-4o-128k"}, want: 128000},
		{name: "claude 走 128k", cfg: &domain.AIConfig{Model: "claude-3-5-sonnet"}, want: 128000},
		{name: "qwen 走 32k", cfg: &domain.AIConfig{Model: "qwen-plus"}, want: 32000},
		{name: "未知模型兜底 8k", cfg: &domain.AIConfig{Model: "gpt-4o-mini"}, want: 8000},
		{name: "nil 配置兜底 8k", cfg: nil, want: 8000},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := aiContextWindow(c.cfg); got != c.want {
				t.Fatalf("期望 %d，实际 %d", c.want, got)
			}
		})
	}
}

// 预算不足时必须丢片段，且至少留一段——全丢光模型只能编。
func TestBuildContextRespectsBudget(t *testing.T) {
	book := &domain.Book{ID: 1, Name: "测试书"}
	texts := make([]string, 10)
	for i := range texts {
		texts[i] = longText(200, fmt.Sprintf("第%d段 ", i+1))
	}
	hits := make([]aiRetrieved, len(texts))
	for i, s := range texts {
		hits[i] = aiRetrieved{
			Chunk: &domain.AIChunk{ID: int64(i + 1), ChapterIdx: i, Title: "第1章", Text: s},
			Score: 1 - float64(i)/20,
		}
	}
	svc := newRecallService(nil, &fakeLLM{})
	cfg := &domain.AIConfig{Model: "mock", ContextWindow: 1000} // 预算 600

	out := svc.buildContext(context.Background(), cfg, book, aiRecallResult{Hits: hits})

	if out.Budget != 600 {
		t.Fatalf("预算应为 600，实际 %d", out.Budget)
	}
	if len(out.Refs) == 0 {
		t.Fatal("至少要带一段资料")
	}
	if out.UsedTokens > out.Budget {
		t.Fatalf("超预算：%d > %d", out.UsedTokens, out.Budget)
	}
	if out.Dropped == 0 {
		t.Fatal("预算装不下时应记录丢弃的片段数")
	}
	if out.Note == "" {
		t.Fatal("丢弃片段时应给出说明")
	}
}

// 全书摘要是最划算的资料，必须进上下文。
func TestBuildContextIncludesBookSummary(t *testing.T) {
	book := &domain.Book{ID: 1}
	sums := newFakeSummaryRepo()
	if err := sums.Put(context.Background(), &domain.AISummary{
		BookID: 1, Level: 3, Ordinal: 0, Content: "全书讲了刀具几何角度与磨损机理。",
		ChapterFrom: 0, ChapterTo: 9, OK: true,
	}); err != nil {
		t.Fatalf("写入摘要失败: %v", err)
	}
	svc := NewAIService(AIDeps{Summaries: sums})
	cfg := &domain.AIConfig{Model: "mock", ContextWindow: 4000}

	out := svc.buildContext(context.Background(), cfg, book, aiRecallResult{})
	all := joinMessages(out.Messages)
	if !strings.Contains(all, "【全书摘要】") || !strings.Contains(all, "刀具几何角度") {
		t.Fatalf("上下文应包含全书摘要: %q", all)
	}
}

// 章节摘要与命中章节无交集时不该出现（白占预算）。
func TestBuildContextChapterSummariesOnlyWhenRelevant(t *testing.T) {
	book := &domain.Book{ID: 1}
	sums := newFakeSummaryRepo()
	_ = sums.Put(context.Background(), &domain.AISummary{
		BookID: 1, Level: 1, Ordinal: 0, Content: "第 1~2 章讲了刀具材料。",
		ChapterFrom: 0, ChapterTo: 2, OK: true,
	})
	svc := NewAIService(AIDeps{Summaries: sums})
	cfg := &domain.AIConfig{Model: "mock", ContextWindow: 8000}

	// 命中的是第 50 章，与摘要区间无关。
	hit := aiRetrieved{Chunk: &domain.AIChunk{ID: 1, ChapterIdx: 50, Title: "第51章", Text: "无关正文"}, Score: 1}
	out := svc.buildContext(context.Background(), cfg, book, aiRecallResult{Hits: []aiRetrieved{hit}})
	if strings.Contains(joinMessages(out.Messages), "分章摘要") {
		t.Fatalf("不相关章节的摘要不该被塞进上下文: %q", joinMessages(out.Messages))
	}

	// 换成命中第 1 章，摘要应出现。
	hit2 := aiRetrieved{Chunk: &domain.AIChunk{ID: 2, ChapterIdx: 1, Title: "第2章", Text: "刀具材料"}, Score: 1}
	out2 := svc.buildContext(context.Background(), cfg, book, aiRecallResult{Hits: []aiRetrieved{hit2}})
	if !strings.Contains(joinMessages(out2.Messages), "分章摘要") {
		t.Fatalf("命中章节的摘要应进入上下文: %q", joinMessages(out2.Messages))
	}
}

// 引用编号必须与提示里的 [1]..[K] 对齐，否则前端跳转会指错片段。
func TestBuildContextRefsAlignWithExcerpts(t *testing.T) {
	book := &domain.Book{ID: 1}
	svc := newRecallService(nil, &fakeLLM{})
	cfg := &domain.AIConfig{Model: "mock", ContextWindow: 8000}

	hits := []aiRetrieved{
		{Chunk: &domain.AIChunk{ID: 11, ChapterIdx: 3, Title: "第4章", Text: "甲段正文"}, Score: 0.9},
		{Chunk: &domain.AIChunk{ID: 12, ChapterIdx: 5, Title: "第6章", Text: "乙段正文"}, Score: 0.8},
	}
	out := svc.buildContext(context.Background(), cfg, book, aiRecallResult{Hits: hits})

	if len(out.Refs) != 2 {
		t.Fatalf("应有 2 条引用，实际 %d", len(out.Refs))
	}
	all := joinMessages(out.Messages)
	for i, ref := range out.Refs {
		if !strings.Contains(all, fmt.Sprintf("[%d] %s", i+1, ref.Title)) {
			t.Fatalf("第 %d 条引用与提示编号不对齐: %q", i+1, all)
		}
		if ref.ChunkID != hits[i].Chunk.ID || ref.ChapterIdx != hits[i].Chunk.ChapterIdx {
			t.Fatalf("引用内容不符: %+v", ref)
		}
		if ref.Excerpt == "" {
			t.Fatalf("引用应带摘录: %+v", ref)
		}
	}
}

// 完全没有资料时也要能问：给一句明确说明，而不是塞空上下文让模型瞎猜。
func TestBuildContextWithoutMaterial(t *testing.T) {
	svc := newRecallService(nil, &fakeLLM{})
	out := svc.buildContext(context.Background(), &domain.AIConfig{Model: "mock"},
		&domain.Book{ID: 1}, aiRecallResult{})
	all := joinMessages(out.Messages)
	if !strings.Contains(all, "还没有可用资料") {
		t.Fatalf("无资料时应明确告知模型: %q", all)
	}
	if len(out.Refs) != 0 {
		t.Fatalf("无资料不该有引用: %+v", out.Refs)
	}
}

// 截断按字符数，不能把多字节字符切成乱码。
func TestExcerptRunes(t *testing.T) {
	if got := excerptRunes("短文本", 10); got != "短文本" {
		t.Fatalf("未超长时不该改动: %q", got)
	}
	got := excerptRunes("一二三四五", 3)
	if got != "一二三…" {
		t.Fatalf("截断不符: %q", got)
	}
	// emoji 是 4 字节单字符，按 rune 截断不会切坏。
	if got := excerptRunes("😀😀😀😀", 2); got != "😀😀…" {
		t.Fatalf("emoji 截断不符: %q", got)
	}
}

func joinMessages(msgs []port.ChatMessage) string {
	var sb strings.Builder
	for _, m := range msgs {
		sb.WriteString(m.Content)
		sb.WriteString("\n")
	}
	return sb.String()
}
