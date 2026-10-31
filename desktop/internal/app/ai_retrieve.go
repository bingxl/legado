package app

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"
	"unicode"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ── 召回 ────────────────────────────────────────────────────
//
// 混合召回 = 向量（主力）+ 关键词（补充与降级）。
//
// 为什么必须有关键词通道：相当一部分 OpenAI 兼容服务没有 embedding 接口
// （DeepSeek、Moonshot 等），只做向量召回的话这些用户一问就废。
// 反过来只用关键词也不行：同义改写、跨语言提问都召回不到。
// 两者混用，缺一条通道时功能仍在，只是精度下降。

// aiRetrieved 是一条召回结果。
type aiRetrieved struct {
	Chunk *domain.AIChunk
	// Score 是融合后的分数（0~1），用于排序与展示。
	Score float64
	// Vector / Keyword 是两路各自的原始分，便于排查「为什么召回了这条」。
	Vector  float64
	Keyword float64
}

// aiRecallResult 是一次召回的结果与降级信息。
type aiRecallResult struct {
	Hits []aiRetrieved
	// UsedVector 表示本次真的用上了向量通道。
	UsedVector bool
	// Note 记录降级原因（例如向量服务不可用），供界面如实告知用户。
	Note string
}

// 两路分数的权重。向量是主力，但没有它时关键词就是全部。
const (
	aiVectorWeight  = 0.7
	aiKeywordWeight = 0.3
)

// recall 混合召回与提问最相关的切片。
//
// 任何一步失败都不应让提问不可用：向量失败降级为关键词，关键词为空就返回空，
// 由上层决定「没有资料也照常回答」。
func (s *AIService) recall(ctx context.Context, cfg *domain.AIConfig,
	bookID int64, query string, topK int) aiRecallResult {

	if s.chunks == nil {
		return aiRecallResult{Note: "索引未就绪"}
	}
	if topK <= 0 {
		topK = aiDefaultTopK
	}
	chunks, err := s.chunks.List(ctx, bookID)
	if err != nil {
		return aiRecallResult{Note: "读取索引失败：" + err.Error()}
	}
	if len(chunks) == 0 {
		return aiRecallResult{Note: "这本书还没有建立索引"}
	}

	res := aiRecallResult{}

	// ① 向量路：有配置、有向量才算。
	vecScores := map[int64]float64{}
	skipped := 0
	if cfg != nil && cfg.HasEmbedding() {
		vecs, err := s.llm.Embed(ctx, *cfg, cfg.EmbeddingModel, []string{query})
		switch {
		case err != nil:
			res.Note = "向量检索不可用，已改用关键词匹配：" + err.Error()
		case len(vecs) == 0 || len(vecs[0]) == 0:
			res.Note = "向量服务返回了空向量，已改用关键词匹配"
		default:
			q := vecs[0]
			for _, c := range chunks {
				if !c.HasVector() {
					continue
				}
				if len(c.Embedding) != len(q) {
					// 换过 embedding 模型，维度对不上：这些切片参与不了检索。
					skipped++
					continue
				}
				vecScores[c.ID] = cosineSimilarity(q, c.Embedding)
			}
			res.UsedVector = len(vecScores) > 0
			if !res.UsedVector {
				res.Note = "索引里还没有可用的向量，已改用关键词匹配"
			}
		}
	} else {
		res.Note = "未配置向量模型，正在用关键词匹配"
	}
	if skipped > 0 {
		if res.Note != "" {
			res.Note += "；"
		}
		res.Note += fmt.Sprintf("有 %d 片向量维度不一致，建议重建索引", skipped)
	}

	// ② 关键词路：始终跑，既补召回也做降级通道。
	kwScores := keywordScores(aiTerms(query), chunks)

	// ③ 融合：先取两路各自的候选，再合并去重，避免只留一路的 top-K 把另一路的好结果挤掉。
	candidates := map[int64]struct{}{}
	for _, id := range topIDs(vecScores, topK) {
		candidates[id] = struct{}{}
	}
	for _, id := range topIDs(kwScores, topK) {
		candidates[id] = struct{}{}
	}

	byID := make(map[int64]*domain.AIChunk, len(chunks))
	for _, c := range chunks {
		byID[c.ID] = c
	}

	hits := make([]aiRetrieved, 0, len(candidates))
	for id := range candidates {
		c, ok := byID[id]
		if !ok {
			continue
		}
		v := clamp01(vecScores[id])
		k := clamp01(kwScores[id])
		score := k
		if res.UsedVector {
			// 只有该片真的有向量时，向量分才有意义；否则会把它拉到 0。
			if _, has := vecScores[id]; has {
				score = aiVectorWeight*v + aiKeywordWeight*k
			}
		}
		hits = append(hits, aiRetrieved{Chunk: c, Score: score, Vector: v, Keyword: k})
	}
	sort.SliceStable(hits, func(i, j int) bool {
		if hits[i].Score != hits[j].Score {
			return hits[i].Score > hits[j].Score
		}
		// 同分时按阅读顺序，结果稳定且更符合「先看前面的内容」的直觉。
		return hits[i].Chunk.Ordinal < hits[j].Chunk.Ordinal
	})
	if len(hits) > topK {
		hits = hits[:topK]
	}
	res.Hits = hits
	return res
}

// topIDs 取分数最高的 k 个 key（只用于挑候选，排序交给融合后的统一排序）。
func topIDs(scores map[int64]float64, k int) []int64 {
	if len(scores) == 0 {
		return nil
	}
	type kv struct {
		id    int64
		score float64
	}
	list := make([]kv, 0, len(scores))
	for id, sc := range scores {
		list = append(list, kv{id, sc})
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].score > list[j].score })
	if len(list) > k {
		list = list[:k]
	}
	out := make([]int64, len(list))
	for i, e := range list {
		out[i] = e.id
	}
	return out
}

func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

// ── 关键词打分（bigram TF-IDF）───────────────────────────────

// keywordScores 计算每个切片与查询的关键词相关度，结果归一到 0~1。
//
// 不引分词库：中文按二元切分（bigram）是经典的无词典方案，
// 对短查询的效果接近分词，且零依赖、无词典体积。
func keywordScores(terms []string, chunks []*domain.AIChunk) map[int64]float64 {
	out := make(map[int64]float64, len(chunks))
	if len(terms) == 0 || len(chunks) == 0 {
		return out
	}

	// 先算文档频率：出现在越多切片里的词越不值钱（「的」「是」这类）。
	df := make(map[string]int, len(terms)*4)
	tfs := make([]map[string]int, len(chunks))
	for i, c := range chunks {
		tf := make(map[string]int, 64)
		for _, t := range aiBigrams(c.Text) {
			tf[t]++
		}
		tfs[i] = tf
		for t := range tf {
			df[t]++
		}
	}

	n := float64(len(chunks))
	raw := make([]float64, len(chunks))
	maxRaw := 0.0
	for i := range chunks {
		score := 0.0
		for _, t := range terms {
			tf := tfs[i][t]
			if tf == 0 {
				continue
			}
			// 平滑 IDF：只在少数切片出现的词权重更高，但不至于因 N 小而无意义。
			idf := math.Log(1 + n/(1+float64(df[t])))
			// 词频用对数压一下：出现十次不等于十倍相关。
			score += idf * (1 + math.Log(float64(tf)))
		}
		raw[i] = score
		if score > maxRaw {
			maxRaw = score
		}
	}
	if maxRaw == 0 {
		return out
	}
	for i, c := range chunks {
		if raw[i] > 0 {
			out[c.ID] = raw[i] / maxRaw
		}
	}
	return out
}

// aiTerms 把查询拆成不重复的关键词。
func aiTerms(query string) []string {
	seen := make(map[string]struct{}, 32)
	out := make([]string, 0, 32)
	for _, t := range aiBigrams(query) {
		if _, ok := seen[t]; ok {
			continue
		}
		seen[t] = struct{}{}
		out = append(out, t)
	}
	return out
}

// aiBigrams 把文本切成关键词单元。
//
// 规则：连续汉字取相邻二元组（单字也保留，否则「爱」这类单字查询永远命中不了）；
// 连续字母数字按整词处理并转小写；汉字与 ASCII 相邻处断开，
// 避免「iPad保护壳」被拼成一个查不到的词。
func aiBigrams(text string) []string {
	out := make([]string, 0, len(text)/2+1)
	buf := make([]rune, 0, 16)

	flush := func() {
		if len(buf) == 0 {
			return
		}
		if isCJK(buf[0]) {
			if len(buf) == 1 {
				out = append(out, string(buf))
			}
			for i := 0; i+1 < len(buf); i++ {
				out = append(out, string(buf[i:i+2]))
			}
		} else {
			out = append(out, strings.ToLower(string(buf)))
		}
		buf = buf[:0]
	}

	for _, r := range text {
		if !isCJK(r) && !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			flush()
			continue
		}
		if len(buf) > 0 && isCJK(buf[len(buf)-1]) != isCJK(r) {
			flush()
		}
		buf = append(buf, r)
	}
	flush()
	return out
}

func isCJK(r rune) bool { return r >= 0x4E00 && r <= 0x9FFF }

// ── 上下文装配 ──────────────────────────────────────────────

// aiContextWindow 推定模型上下文窗口（token）。
//
// 按模型名猜是因为没有统一接口能查到；猜错的最坏结果是塞得偏保守，
// 不会把请求搞失败。用户显式填了 ContextWindow 时以填的为准。
func aiContextWindow(cfg *domain.AIConfig) int {
	if cfg != nil && cfg.ContextWindow > 0 {
		return cfg.ContextWindow
	}
	name := ""
	if cfg != nil {
		name = strings.ToLower(cfg.Model)
	}
	switch {
	case strings.Contains(name, "128k"), strings.Contains(name, "claude"),
		strings.Contains(name, "qwen-long"), strings.Contains(name, "gemini"):
		return 128000
	case strings.Contains(name, "32k"), strings.Contains(name, "qwen"),
		strings.Contains(name, "glm-4"):
		return 32000
	case strings.Contains(name, "16k"):
		return 16000
	}
	// 兜底 8k：宁可保守，也不要因低估而整次调用失败。
	return 8000
}

// aiContext 是装配好的提问上下文。
type aiContext struct {
	Messages []port.ChatMessage
	// Refs 与提示里 [1]..[K] 的编号一一对应，供前端跳转高亮。
	Refs []domain.AIRef
	// UsedTokens 是资料部分占用的估算 token，用于日志与测试。
	UsedTokens int
	// Budget 是本次可用的资料预算。
	Budget int
	// Note 记录装配时的取舍（例如「资料过长，只取了前 5 段」）。
	Note string
	// DroppedChapters 表示因预算不足而放弃的切片数。
	Dropped int
}

// 资料占上下文窗口的比例：其余留给系统提示与回答。
const aiContextRatio = 0.6

// 引用片段的截断长度（rune）。太长的片段会挤掉其它片段，太短又看不出上下文。
const aiExcerptRunes = 600

// buildContext 把召回结果装配成可发给模型的消息。
//
// 优先级（预算不够时从后往前丢）：
//  1. 系统提示
//  2. 全书摘要（压缩过，性价比最高）
//  3. 命中片段原文
//  4. 章节摘要（空间不够时最先舍弃）
func (s *AIService) buildContext(ctx context.Context, cfg *domain.AIConfig,
	book *domain.Book, recall aiRecallResult) aiContext {

	window := aiContextWindow(cfg)
	budget := int(float64(window) * aiContextRatio)
	out := aiContext{Budget: budget}

	out.Messages = append(out.Messages, port.ChatMessage{
		Role:    domain.AIRoleSystem,
		Content: aiAnswerSystemPrompt,
	})
	used := estimateTokens(aiAnswerSystemPrompt)

	// ② 全书摘要：先占位，非常便宜。
	var material strings.Builder
	if s.summaries != nil {
		if top, err := s.summaries.Top(ctx, book.ID); err == nil && top != nil && top.OK {
			text := strings.TrimSpace(top.Content)
			if text != "" {
				section := "【全书摘要】\n" + text + "\n\n"
				used += estimateTokens(section)
				material.WriteString(section)
			}
		}
	}

	// ③ 命中片段：按分数降序塞，塞满为止。
	excerpts := make([]string, 0, len(recall.Hits))
	refs := make([]domain.AIRef, 0, len(recall.Hits))
	for i, hit := range recall.Hits {
		body := excerptRunes(hit.Chunk.Text, aiExcerptRunes)
		label := fmt.Sprintf("[%d] %s\n%s\n\n", i+1, hit.Chunk.Title, body)
		cost := estimateTokens(label)
		if used+cost > budget && len(refs) > 0 {
			// 至少留一段资料：否则模型只能凭空编。
			out.Dropped = len(recall.Hits) - i
			break
		}
		used += cost
		excerpts = append(excerpts, label)
		refs = append(refs, domain.AIRef{
			ChunkID:    hit.Chunk.ID,
			ChapterIdx: hit.Chunk.ChapterIdx,
			Title:      hit.Chunk.Title,
			Score:      hit.Score,
			Excerpt:    excerptRunes(hit.Chunk.Text, 160),
		})
	}

	// ④ 章节摘要：预算还剩才加，它是四项里最容易被替代的。
	if chapterPart := s.chapterSummaries(ctx, book.ID, refs, budget-used); chapterPart != "" {
		material.WriteString(chapterPart)
		used += estimateTokens(chapterPart)
	}

	if len(excerpts) > 0 {
		material.WriteString("【原文片段】\n")
		for _, e := range excerpts {
			material.WriteString(e)
		}
	}
	if material.Len() == 0 {
		material.WriteString("【资料】\n（这本书还没有可用资料，请根据常识回答并说明这一点。）\n")
	}

	out.Messages = append(out.Messages, port.ChatMessage{
		Role:    domain.AIRoleSystem,
		Content: material.String(),
	})
	out.Refs = refs
	out.UsedTokens = used
	if out.Dropped > 0 {
		out.Note = fmt.Sprintf("资料超出上下文预算，只带了前 %d 段原文", len(refs))
	}
	return out
}

// chapterSummaries 取命中章节对应的段摘要（level 1），按剩余预算截断。
func (s *AIService) chapterSummaries(ctx context.Context, bookID int64,
	refs []domain.AIRef, remaining int) string {

	if s.summaries == nil || remaining <= 200 || len(refs) == 0 {
		return ""
	}
	levels, err := s.summaries.Level(ctx, bookID, 1)
	if err != nil || len(levels) == 0 {
		return ""
	}

	hit := make(map[int]struct{}, len(refs))
	for _, r := range refs {
		hit[r.ChapterIdx] = struct{}{}
	}

	var sb strings.Builder
	for _, sm := range levels {
		if !sm.OK || strings.TrimSpace(sm.Content) == "" {
			continue
		}
		// ChapterFrom/To 是区间：只要与命中章节有交集就算相关。
		overlap := false
		for ch := range hit {
			if ch >= sm.ChapterFrom && ch <= sm.ChapterTo {
				overlap = true
				break
			}
		}
		if !overlap {
			continue
		}
		line := fmt.Sprintf("【第 %d~%d 章摘要】\n%s\n", sm.ChapterFrom+1, sm.ChapterTo+1, sm.Content)
		cost := estimateTokens(line)
		if cost > remaining {
			break
		}
		remaining -= cost
		sb.WriteString(line)
	}
	if sb.Len() == 0 {
		return ""
	}
	return "【分章摘要】\n" + sb.String() + "\n"
}

// excerptRunes 按字符数截断，避免切坏多字节字符。
func excerptRunes(s string, limit int) string {
	rs := []rune(strings.TrimSpace(s))
	if len(rs) <= limit {
		return string(rs)
	}
	return string(rs[:limit]) + "…"
}

// aiAnswerSystemPrompt 是问答的系统提示。
//
// 明确要求「标注出处」和「不知道就说不知道」：基于书籍问答最怕的是
// 模型把通用知识混进书里的内容，用户无法分辨哪句是原文、哪句是编的。
const aiAnswerSystemPrompt = `你在帮助用户理解一本书。规则：
1. 只依据【资料】回答，不要引入书籍之外的知识；资料里没有就说「书里这部分没有提到」。
2. 引用原文时用 [1] [2] 这样的编号标注出处，编号对应【原文片段】。
3. 用简体中文回答，简洁直接，不要复述问题，不要写「根据资料」这类导语。
4. 涉及情节或数据时给出具体章节与名词，不要泛泛而谈。`
