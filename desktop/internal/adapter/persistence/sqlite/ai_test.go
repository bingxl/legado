package sqlite

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/legado/desktop/internal/domain"
)

// seedBook 插入一本测试书，满足 ai_* 表的外键约束。
func seedBook(t *testing.T, db *DB, name string) int64 {
	t.Helper()
	b := &domain.Book{
		Name:    name,
		Kind:    domain.BookKindWeb,
		Format:  domain.BookFormatTXT,
		Origin:  "https://example.com/src",
		BookURL: "https://example.com/book/" + name,
	}
	if err := NewBookRepo(db).Create(context.Background(), b); err != nil {
		t.Fatalf("插入测试书失败: %v", err)
	}
	return b.ID
}

func TestVectorCodecRoundTrip(t *testing.T) {
	cases := [][]float32{
		nil,
		{},
		{0},
		{1.5, -2.25, 0, 1e-8, 3.4e38},
	}
	for _, in := range cases {
		out := decodeVector(encodeVector(in))
		if len(in) == 0 {
			if len(out) != 0 {
				t.Fatalf("空向量应解出空，实际 %v", out)
			}
			continue
		}
		if len(out) != len(in) {
			t.Fatalf("长度不一致: %d vs %d", len(out), len(in))
		}
		for i := range in {
			if out[i] != in[i] {
				t.Fatalf("第 %d 个分量不一致: %v vs %v", i, out[i], in[i])
			}
		}
	}
}

func TestVectorDecodeRejectsTruncated(t *testing.T) {
	// 残缺 BLOB（列被外部工具改坏）应返回 nil 而不是越界 panic。
	if v := decodeVector([]byte{1, 2, 3}); v != nil {
		t.Fatalf("不足 4 字节应返回 nil，实际 %v", v)
	}
}

func TestAIChunkPutBulkAndList(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	bookID := seedBook(t, db, "切片书")
	repo := NewAIChunkRepo(db)

	chunks := []*domain.AIChunk{
		{BookID: bookID, ChapterIdx: 0, Ordinal: 0, CharStart: 0, CharEnd: 10,
			Title: "第一章", Text: "开头一段", TokenCount: 5, SrcHash: "h1",
			Embedding: []float32{0.1, 0.2}, EmbModel: "m", EmbDim: 2},
		{BookID: bookID, ChapterIdx: 0, Ordinal: 1, CharStart: 8, CharEnd: 20,
			Title: "第一章", Text: "接着一段", TokenCount: 4, SrcHash: "h2"},
		{BookID: bookID, ChapterIdx: 1, Ordinal: 2, CharStart: 0, CharEnd: 9,
			Title: "第二章", Text: "另一章", TokenCount: 3, SrcHash: "h3"},
	}
	if err := repo.PutBulk(ctx, chunks); err != nil {
		t.Fatalf("写入失败: %v", err)
	}

	n, err := repo.Count(ctx, bookID)
	if err != nil || n != 3 {
		t.Fatalf("Count = %d, err = %v", n, err)
	}

	list, err := repo.List(ctx, bookID)
	if err != nil {
		t.Fatalf("List 失败: %v", err)
	}
	if len(list) != 3 {
		t.Fatalf("List 返回 %d 条", len(list))
	}
	// 必须按 ordinal 升序，否则拼接上下文时顺序会乱。
	for i, c := range list {
		if c.Ordinal != i {
			t.Fatalf("第 %d 条 ordinal = %d，顺序错误", i, c.Ordinal)
		}
	}
	if len(list[0].Embedding) != 2 || list[0].Embedding[1] != 0.2 {
		t.Fatalf("向量未正确往返: %v", list[0].Embedding)
	}
	if list[0].CreatedAt.IsZero() {
		t.Fatal("CreatedAt 未自动填充")
	}

	// 区间查询
	rng, err := repo.ListRange(ctx, bookID, 1, 2)
	if err != nil || len(rng) != 2 {
		t.Fatalf("ListRange = %d 条, err = %v", len(rng), err)
	}
	if rng[0].Ordinal != 1 || rng[1].Ordinal != 2 {
		t.Fatalf("区间边界错误: %d..%d", rng[0].Ordinal, rng[1].Ordinal)
	}
}

func TestAIChunkPutBulkKeepsVectorWhenHashUnchanged(t *testing.T) {
	// 重跑索引时若正文没变，绝不能把已经花过钱的向量丢掉。
	db := newTestDB(t)
	ctx := context.Background()
	bookID := seedBook(t, db, "保留向量")
	repo := NewAIChunkRepo(db)

	first := []*domain.AIChunk{{
		BookID: bookID, ChapterIdx: 0, Ordinal: 0, Text: "原文", SrcHash: "same",
		Embedding: []float32{1, 2, 3}, EmbModel: "m", EmbDim: 3,
	}}
	if err := repo.PutBulk(ctx, first); err != nil {
		t.Fatalf("首次写入失败: %v", err)
	}

	second := []*domain.AIChunk{{
		BookID: bookID, ChapterIdx: 0, Ordinal: 0, Text: "原文（标题变了）", SrcHash: "same",
	}}
	if err := repo.PutBulk(ctx, second); err != nil {
		t.Fatalf("二次写入失败: %v", err)
	}

	got, err := repo.List(ctx, bookID)
	if err != nil || len(got) != 1 {
		t.Fatalf("List 失败: %v", err)
	}
	if len(got[0].Embedding) != 3 {
		t.Fatalf("hash 未变却丢了向量: %v", got[0].Embedding)
	}
	if got[0].Text != "原文（标题变了）" {
		t.Fatalf("文本未更新: %q", got[0].Text)
	}
}

func TestAIChunkPutBulkClearsVectorWhenHashChanged(t *testing.T) {
	// 正文变了，旧向量与新文本不再对应，必须作废。
	db := newTestDB(t)
	ctx := context.Background()
	bookID := seedBook(t, db, "清空向量")
	repo := NewAIChunkRepo(db)

	if err := repo.PutBulk(ctx, []*domain.AIChunk{{
		BookID: bookID, Ordinal: 0, Text: "旧", SrcHash: "old",
		Embedding: []float32{1, 2}, EmbModel: "m", EmbDim: 2,
	}}); err != nil {
		t.Fatalf("写入失败: %v", err)
	}

	if err := repo.PutBulk(ctx, []*domain.AIChunk{{
		BookID: bookID, Ordinal: 0, Text: "新", SrcHash: "new",
	}}); err != nil {
		t.Fatalf("写入失败: %v", err)
	}

	got, _ := repo.List(ctx, bookID)
	if len(got[0].Embedding) != 0 {
		t.Fatalf("hash 变了却留着旧向量: %v", got[0].Embedding)
	}
	if got[0].EmbDim != 0 || got[0].EmbModel != "" {
		t.Fatalf("向量元信息未清空: %+v", got[0])
	}
}

func TestAIChunkUpdateEmbedding(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	bookID := seedBook(t, db, "更新向量")
	repo := NewAIChunkRepo(db)

	if err := repo.PutBulk(ctx, []*domain.AIChunk{{
		BookID: bookID, Ordinal: 0, Text: "x", SrcHash: "h",
	}}); err != nil {
		t.Fatalf("写入失败: %v", err)
	}
	list, _ := repo.List(ctx, bookID)
	id := list[0].ID

	if err := repo.UpdateEmbedding(ctx, id, []float32{0.5, 0.6}, "emb", 2); err != nil {
		t.Fatalf("更新向量失败: %v", err)
	}
	got, err := repo.Get(ctx, id)
	if err != nil {
		t.Fatalf("Get 失败: %v", err)
	}
	if len(got.Embedding) != 2 || got.Embedding[0] != 0.5 || got.EmbDim != 2 {
		t.Fatalf("向量未更新: %+v", got)
	}

	if err := repo.UpdateEmbedding(ctx, 999999, nil, "", 0); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("不存在的 id 应返回 ErrNotFound，实际 %v", err)
	}
}

func TestAIChunkDeleteByChapters(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	bookID := seedBook(t, db, "局部删除")
	repo := NewAIChunkRepo(db)

	var chunks []*domain.AIChunk
	for i := 0; i < 5; i++ {
		chunks = append(chunks, &domain.AIChunk{
			BookID: bookID, ChapterIdx: i, Ordinal: i, Text: "t", SrcHash: "h",
		})
	}
	if err := repo.PutBulk(ctx, chunks); err != nil {
		t.Fatalf("写入失败: %v", err)
	}

	if err := repo.DeleteByChapters(ctx, bookID, 1, 2); err != nil {
		t.Fatalf("删除失败: %v", err)
	}
	n, _ := repo.Count(ctx, bookID)
	if n != 3 {
		t.Fatalf("应剩 3 条，实际 %d", n)
	}
	left, _ := repo.List(ctx, bookID)
	if left[0].ChapterIdx != 0 || left[1].ChapterIdx != 3 {
		t.Fatalf("删除范围错误: %d, %d", left[0].ChapterIdx, left[1].ChapterIdx)
	}
}

func TestAIChunkCascadesOnBookDelete(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	bookID := seedBook(t, db, "级联删除")
	repo := NewAIChunkRepo(db)

	if err := repo.PutBulk(ctx, []*domain.AIChunk{{
		BookID: bookID, Ordinal: 0, Text: "t", SrcHash: "h",
	}}); err != nil {
		t.Fatalf("写入失败: %v", err)
	}
	if err := NewBookRepo(db).Delete(ctx, bookID); err != nil {
		t.Fatalf("删除书失败: %v", err)
	}
	n, _ := repo.Count(ctx, bookID)
	if n != 0 {
		t.Fatalf("删书后切片应级联清除，实际剩 %d", n)
	}
}

func TestAISummaryLevelsAndTop(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	bookID := seedBook(t, db, "摘要书")
	repo := NewAISummaryRepo(db)

	if _, err := repo.Top(ctx, bookID); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("无摘要时应 ErrNotFound，实际 %v", err)
	}
	lv, err := repo.MaxLevel(ctx, bookID)
	if err != nil || lv != 0 {
		t.Fatalf("MaxLevel = %d, err = %v", lv, err)
	}

	items := []*domain.AISummary{
		{BookID: bookID, Level: 1, Ordinal: 0, Content: "段一", OK: true, Model: "m"},
		{BookID: bookID, Level: 1, Ordinal: 1, Content: "段二", OK: true, Model: "m"},
		{BookID: bookID, Level: 2, Ordinal: 0, Content: "全书", OK: true, Model: "m"},
	}
	for _, it := range items {
		if err := repo.Put(ctx, it); err != nil {
			t.Fatalf("写入摘要失败: %v", err)
		}
	}

	lv, _ = repo.MaxLevel(ctx, bookID)
	if lv != 2 {
		t.Fatalf("MaxLevel = %d, 期望 2", lv)
	}
	top, err := repo.Top(ctx, bookID)
	if err != nil || top.Content != "全书" {
		t.Fatalf("Top = %+v, err = %v", top, err)
	}
	l1, err := repo.Level(ctx, bookID, 1)
	if err != nil || len(l1) != 2 {
		t.Fatalf("Level(1) = %d 条, err = %v", len(l1), err)
	}

	// 覆盖写：同 (book, level, ordinal) 应更新而不是新增
	if err := repo.Put(ctx, &domain.AISummary{
		BookID: bookID, Level: 1, Ordinal: 0, Content: "段一（改）", OK: false, Error: "失败",
	}); err != nil {
		t.Fatalf("覆盖写失败: %v", err)
	}
	l1, _ = repo.Level(ctx, bookID, 1)
	if len(l1) != 2 {
		t.Fatalf("覆盖写产生了重复行，实际 %d 条", len(l1))
	}
	if l1[0].Content != "段一（改）" || l1[0].OK || l1[0].Error != "失败" {
		t.Fatalf("覆盖写未生效: %+v", l1[0])
	}
	if l1[0].UpdatedAt.IsZero() || l1[0].CreatedAt.IsZero() {
		t.Fatal("时间字段未填充")
	}
}

func TestAISummaryDeleteFromLevel(t *testing.T) {
	// 下层变了上层就失效，必须能整段作废。
	db := newTestDB(t)
	ctx := context.Background()
	bookID := seedBook(t, db, "摘要作废")
	repo := NewAISummaryRepo(db)

	for lv := 1; lv <= 3; lv++ {
		if err := repo.Put(ctx, &domain.AISummary{
			BookID: bookID, Level: lv, Ordinal: 0, Content: "x", OK: true,
		}); err != nil {
			t.Fatalf("写入失败: %v", err)
		}
	}
	if err := repo.DeleteFromLevel(ctx, bookID, 2); err != nil {
		t.Fatalf("删除失败: %v", err)
	}
	if lv, _ := repo.MaxLevel(ctx, bookID); lv != 1 {
		t.Fatalf("删除后 MaxLevel = %d，期望 1", lv)
	}
	if l1, _ := repo.Level(ctx, bookID, 1); len(l1) != 1 {
		t.Fatalf("第 1 层不应被删，实际 %d 条", len(l1))
	}
}

func TestAIIndexStateRoundTrip(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	bookID := seedBook(t, db, "状态书")
	repo := NewAIIndexStateRepo(db)

	if _, err := repo.Get(ctx, bookID); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("未写入时应 ErrNotFound，实际 %v", err)
	}

	st := &domain.AIIndexState{
		BookID: bookID, Scope: domain.AIScopeRead, ChapterFrom: 0, ChapterTo: 42,
		Status: domain.AIIndexRunning, ChunkCount: 120, EmbDone: 80,
		SummaryDone: 3, SummaryTotal: 15,
	}
	if err := repo.Put(ctx, st); err != nil {
		t.Fatalf("写入状态失败: %v", err)
	}

	got, err := repo.Get(ctx, bookID)
	if err != nil {
		t.Fatalf("读取状态失败: %v", err)
	}
	if got.Scope != domain.AIScopeRead || got.ChapterTo != 42 || got.EmbDone != 80 ||
		got.SummaryTotal != 15 || got.Status != domain.AIIndexRunning {
		t.Fatalf("状态往返不一致: %+v", got)
	}
	if got.UpdatedAt.IsZero() {
		t.Fatal("UpdatedAt 未自动填充")
	}

	// 覆盖写
	st.Status = domain.AIIndexDone
	st.EmbDone = 120
	if err := repo.Put(ctx, st); err != nil {
		t.Fatalf("覆盖写失败: %v", err)
	}
	got, _ = repo.Get(ctx, bookID)
	if got.Status != domain.AIIndexDone || got.EmbDone != 120 {
		t.Fatalf("覆盖写未生效: %+v", got)
	}

	if err := repo.Delete(ctx, bookID); err != nil {
		t.Fatalf("删除失败: %v", err)
	}
	if _, err := repo.Get(ctx, bookID); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("删除后应 ErrNotFound，实际 %v", err)
	}
}

func TestAIChatAndMessages(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	bookID := seedBook(t, db, "会话书")
	repo := NewAIChatRepo(db)

	chat := &domain.AIChat{BookID: bookID, Title: "第一次对话", Scope: "book", Model: "m"}
	if err := repo.CreateChat(ctx, chat); err != nil {
		t.Fatalf("创建会话失败: %v", err)
	}
	if chat.ID == 0 {
		t.Fatal("会话 ID 未回填")
	}

	// 造一个新会话，验证列表按更新时间倒序
	time.Sleep(1100 * time.Millisecond) // updated_at 精度到秒，错开一秒才能验证排序
	chat2 := &domain.AIChat{BookID: bookID, Title: "第二次对话"}
	if err := repo.CreateChat(ctx, chat2); err != nil {
		t.Fatalf("创建会话失败: %v", err)
	}

	list, err := repo.ListChats(ctx, bookID)
	if err != nil || len(list) != 2 {
		t.Fatalf("ListChats = %d 条, err = %v", len(list), err)
	}
	if list[0].ID != chat2.ID {
		t.Fatalf("最新会话应排第一，实际 %d", list[0].ID)
	}

	// 消息与引用往返
	msgs := []*domain.AIMessage{
		{ChatID: chat.ID, Role: domain.AIRoleUser, Content: "主角是谁"},
		{ChatID: chat.ID, Role: domain.AIRoleAssistant, Content: "是张三",
			Refs: []domain.AIRef{{ChunkID: 7, ChapterIdx: 3, Title: "第三章", Score: 0.82, Excerpt: "张三说"}}},
	}
	for _, m := range msgs {
		if err := repo.AddMessage(ctx, m); err != nil {
			t.Fatalf("写入消息失败: %v", err)
		}
		if m.ID == 0 {
			t.Fatal("消息 ID 未回填")
		}
	}

	got, err := repo.Messages(ctx, chat.ID)
	if err != nil || len(got) != 2 {
		t.Fatalf("Messages = %d 条, err = %v", len(got), err)
	}
	if got[0].Role != domain.AIRoleUser || got[1].Content != "是张三" {
		t.Fatalf("消息往返错误: %+v", got)
	}
	if len(got[1].Refs) != 1 || got[1].Refs[0].ChapterIdx != 3 || got[1].Refs[0].Score != 0.82 {
		t.Fatalf("引用未正确反序列化: %+v", got[1].Refs)
	}

	if err := repo.TouchChat(ctx, chat.ID); err != nil {
		t.Fatalf("TouchChat 失败: %v", err)
	}

	// 删会话应连带删消息
	if err := repo.DeleteChat(ctx, chat.ID); err != nil {
		t.Fatalf("删除会话失败: %v", err)
	}
	if _, err := repo.GetChat(ctx, chat.ID); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("删除后应 ErrNotFound，实际 %v", err)
	}
	left, _ := repo.Messages(ctx, chat.ID)
	if len(left) != 0 {
		t.Fatalf("会话删除后消息应清除，实际剩 %d", len(left))
	}
}
