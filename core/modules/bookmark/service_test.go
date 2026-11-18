package bookmark

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/legado/core/adapters/persistence/sqlite"
	"github.com/legado/core/kernel"
)

// newTestModule 建一个独立的内存库并完成建表。
//
// 用带名字的 shared-cache 内存库：本包的多个测试并行跑时各自一份数据，
// 同时连接池只保留一个连接（sqlite.Open 里设的），:memory: 才不会在切连接时丢表。
func newTestModule(t *testing.T) *Module {
	t.Helper()
	dsn := "file:" + strings.ReplaceAll(t.Name(), "/", "_") + "?mode=memory&cache=shared"
	db, err := sqlite.Open(dsn)
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	m := New(db)
	if err := m.Migrate(context.Background()); err != nil {
		t.Fatalf("建表失败: %v", err)
	}
	return m
}

// codeOf 取错误的业务码，便于断言而不依赖文案。
func codeOf(t *testing.T, err error) string {
	t.Helper()
	e := kernel.AsError(err)
	if e == nil {
		return ""
	}
	return e.Code
}

func TestBookmarkCRUD(t *testing.T) {
	ctx := context.Background()
	m := newTestModule(t)

	first, err := m.bm.Add(ctx, 1, 2, "第二章", 120, "摘录内容", "备注")
	if err != nil {
		t.Fatalf("新增书签失败: %v", err)
	}
	if first.ID == 0 {
		t.Fatal("新增后未回填 ID")
	}
	if first.ChapterIndex != 2 || first.ChapterTitle != "第二章" || first.ChapterPos != 120 {
		t.Fatalf("回读字段与写入不一致: %+v", first)
	}
	if first.CreatedAt.IsZero() {
		t.Fatal("createdAt 为零值")
	}
	if d := time.Since(first.CreatedAt); d < -time.Minute || d > time.Minute {
		t.Fatalf("createdAt 偏离当前时间: %v", d)
	}

	// 逐条插入时 created_at 可能落在同一秒，排序靠 id 兜底；
	// 所以这里只断言条数与归属，不假设不同书之间的先后。
	if _, err := m.bm.Add(ctx, 1, 5, "第五章", 0, "", ""); err != nil {
		t.Fatalf("新增第二条书签失败: %v", err)
	}
	if _, err := m.bm.Add(ctx, 2, 1, "第一章", 0, "", ""); err != nil {
		t.Fatalf("新增其他书书签失败: %v", err)
	}

	all, err := m.bm.List(ctx, 0, 0)
	if err != nil {
		t.Fatalf("列出全部书签失败: %v", err)
	}
	if len(all) != 3 {
		t.Fatalf("全部书签应为 3 条，实际 %d", len(all))
	}

	onlyBook1, err := m.bm.List(ctx, 1, 0)
	if err != nil {
		t.Fatalf("按书列出书签失败: %v", err)
	}
	if len(onlyBook1) != 2 {
		t.Fatalf("书 1 应有 2 条书签，实际 %d", len(onlyBook1))
	}

	limited, err := m.bm.List(ctx, 0, 1)
	if err != nil {
		t.Fatalf("带 limit 列书签失败: %v", err)
	}
	if len(limited) != 1 {
		t.Fatalf("limit=1 应只返回 1 条，实际 %d", len(limited))
	}

	n, err := m.bm.CountByBook(ctx, 1)
	if err != nil {
		t.Fatalf("统计书签数失败: %v", err)
	}
	if n != 2 {
		t.Fatalf("书 1 书签数应为 2，实际 %d", n)
	}

	if err := m.bm.UpdateNote(ctx, first.ID, "改过的备注"); err != nil {
		t.Fatalf("修改备注失败: %v", err)
	}
	after, err := m.bm.List(ctx, 1, 0)
	if err != nil {
		t.Fatalf("修改后列书签失败: %v", err)
	}
	hit := false
	for _, it := range after {
		if it.ID == first.ID {
			hit = true
			if it.Note != "改过的备注" {
				t.Fatalf("备注未更新: %q", it.Note)
			}
			// 只改备注，不应动位置与正文。
			if it.ChapterIndex != 2 || it.Content != "摘录内容" {
				t.Fatalf("修改备注波及了其他字段: %+v", it)
			}
		}
	}
	if !hit {
		t.Fatal("修改备注后找不到该书签")
	}

	if err := m.bm.Remove(ctx, first.ID); err != nil {
		t.Fatalf("删除书签失败: %v", err)
	}
	if n, _ := m.bm.CountByBook(ctx, 1); n != 1 {
		t.Fatalf("删除后书 1 应剩 1 条，实际 %d", n)
	}

	if err := m.bm.Remove(ctx, first.ID); codeOf(t, err) != kernel.CodeNotFound {
		t.Fatalf("重复删除应返回 NOT_FOUND，实际 %v", err)
	}
	if err := m.bm.UpdateNote(ctx, first.ID, "x"); codeOf(t, err) != kernel.CodeNotFound {
		t.Fatalf("修改不存在书签应返回 NOT_FOUND，实际 %v", err)
	}
	if _, err := m.bm.Add(ctx, 0, 0, "", 0, "", ""); codeOf(t, err) != kernel.CodeInvalid {
		t.Fatalf("缺 bookId 应返回 INVALID_ARGUMENT，实际 %v", err)
	}
}

func TestRecordAppendDedupAndStats(t *testing.T) {
	ctx := context.Background()
	m := newTestModule(t)

	first, err := m.rec.Append(ctx, 1, "书一", 3, "第三章")
	if err != nil {
		t.Fatalf("追加阅读记录失败: %v", err)
	}
	again, err := m.rec.Append(ctx, 1, "书一", 3, "第三章")
	if err != nil {
		t.Fatalf("重复追加阅读记录失败: %v", err)
	}
	if again.ID != first.ID {
		t.Fatalf("同书同日同章应复用同一条记录，id 从 %d 变成 %d", first.ID, again.ID)
	}
	if again.ReadAt.Before(first.ReadAt) {
		t.Fatalf("重复追加应刷新 read_at 而非回退: %v -> %v", first.ReadAt, again.ReadAt)
	}

	if _, err := m.rec.Append(ctx, 1, "书一", 4, "第四章"); err != nil {
		t.Fatalf("追加不同章失败: %v", err)
	}
	if _, err := m.rec.Append(ctx, 2, "书二", 3, "第三章"); err != nil {
		t.Fatalf("追加其他书同章失败: %v", err)
	}

	st, err := m.rec.Stats(ctx)
	if err != nil {
		t.Fatalf("统计失败: %v", err)
	}
	if st.Records != 3 {
		t.Fatalf("记录数应为 3，实际 %d", st.Records)
	}
	if st.Books != 2 {
		t.Fatalf("书籍数应为 2，实际 %d", st.Books)
	}
	if st.Days != 1 {
		t.Fatalf("天数应为 1（都在今天），实际 %d", st.Days)
	}

	items, err := m.rec.List(ctx, 0, 10)
	if err != nil {
		t.Fatalf("列出阅读记录失败: %v", err)
	}
	if len(items) != 3 {
		t.Fatalf("应列出 3 条，实际 %d", len(items))
	}

	page, err := m.rec.List(ctx, 1, 1)
	if err != nil {
		t.Fatalf("分页列出阅读记录失败: %v", err)
	}
	if len(page) != 1 || page[0].ID != items[1].ID {
		t.Fatalf("分页结果不对: %+v", page)
	}

	if _, err := m.rec.Append(ctx, 0, "", 0, ""); codeOf(t, err) != kernel.CodeInvalid {
		t.Fatalf("缺 bookId 应返回 INVALID_ARGUMENT，实际 %v", err)
	}
}

func TestRecordClear(t *testing.T) {
	ctx := context.Background()
	m := newTestModule(t)

	// 三条记录：两条 3 天前，一条今天。
	for _, ch := range []int{1, 2, 3} {
		if _, err := m.rec.Append(ctx, 1, "书一", ch, ""); err != nil {
			t.Fatalf("追加记录失败: %v", err)
		}
	}
	if _, err := m.db.Execute(ctx, `UPDATE read_record SET read_at = unixepoch() - 3*86400 WHERE chapter_index IN (1, 2)`); err != nil {
		t.Fatalf("回填历史时间失败: %v", err)
	}

	deleted, err := m.rec.Clear(ctx, 2)
	if err != nil {
		t.Fatalf("按天数清理失败: %v", err)
	}
	if deleted != 2 {
		t.Fatalf("应删除 2 条历史记录，实际 %d", deleted)
	}
	left, err := m.rec.List(ctx, 0, 10)
	if err != nil {
		t.Fatalf("清理后列记录失败: %v", err)
	}
	if len(left) != 1 || left[0].ChapterIndex != 3 {
		t.Fatalf("保留的记录不对: %+v", left)
	}

	// 0 表示全部清空。
	deleted, err = m.rec.Clear(ctx, 0)
	if err != nil {
		t.Fatalf("全部清理失败: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("应删除 1 条，实际 %d", deleted)
	}
	st, err := m.rec.Stats(ctx)
	if err != nil {
		t.Fatalf("清空后统计失败: %v", err)
	}
	if st != (RecordStats{}) {
		t.Fatalf("清空后统计应全零，实际 %+v", st)
	}
}

// fakeProgress 是 ProgressReader 的测试替身。
type fakeProgress struct {
	idx int
	err error
}

func (f fakeProgress) Get(context.Context, int64) (int, error) { return f.idx, f.err }

func TestResolveChapter(t *testing.T) {
	ctx := context.Background()
	m := newTestModule(t)

	// 未注入进度：负数降级为 0，显式章节号保持原样。
	if got := resolveChapter(ctx, nil, 1, -1); got != 0 {
		t.Fatalf("nil 读取器应降级为 0，实际 %d", got)
	}
	if got := resolveChapter(ctx, nil, 1, 4); got != 4 {
		t.Fatalf("显式章节号不应被改写，实际 %d", got)
	}
	// 读取失败同样降级，不阻断写入。
	if got := resolveChapter(ctx, fakeProgress{err: context.DeadlineExceeded}, 1, -1); got != 0 {
		t.Fatalf("读取失败应降级为 0，实际 %d", got)
	}

	bm := NewBookmarkService(m.db, fakeProgress{idx: 7})
	item, err := bm.Add(ctx, 1, -1, "当前位置", 0, "", "")
	if err != nil {
		t.Fatalf("按当前位置加书签失败: %v", err)
	}
	if item.ChapterIndex != 7 {
		t.Fatalf("书签应落在第 7 章，实际 %d", item.ChapterIndex)
	}

	rec := NewRecordService(m.db, fakeProgress{idx: 9})
	r, err := rec.Append(ctx, 2, "书二", -1, "")
	if err != nil {
		t.Fatalf("按当前位置记流水失败: %v", err)
	}
	if r.ChapterIndex != 9 {
		t.Fatalf("流水应记在第 9 章，实际 %d", r.ChapterIndex)
	}
}

func TestRegisterMethodsAndCommands(t *testing.T) {
	ctx := context.Background()
	m := newTestModule(t)
	reg := kernel.NewRegistry()
	m.Register(reg)

	for _, name := range []string{
		"Bookmark.Add", "Bookmark.List", "Bookmark.Remove", "Bookmark.UpdateNote", "Bookmark.Count",
		"Record.Append", "Record.List", "Record.Clear", "Record.Stats",
	} {
		if _, ok := reg.Lookup(name); !ok {
			t.Fatalf("方法未注册: %s", name)
		}
	}

	// Sig 必须与实际解码位置一致，否则 schema 导出的 arity 会骗到 Dart 侧。
	wantArity := map[string]int{
		"Bookmark.Add": 6, "Bookmark.List": 2, "Bookmark.Remove": 1,
		"Bookmark.UpdateNote": 2, "Bookmark.Count": 1,
		"Record.Append": 4, "Record.List": 2, "Record.Clear": 1, "Record.Stats": 0,
	}
	for name, want := range wantArity {
		m, _ := reg.Lookup(name)
		if m.Arity != want {
			t.Fatalf("%s arity 应为 %d，实际 %d", name, want, m.Arity)
		}
		if len(m.ParamTypes) != want {
			t.Fatalf("%s 参数类型数应为 %d，实际 %v", name, want, m.ParamTypes)
		}
	}
	if m, _ := reg.Lookup("Bookmark.Add"); m.ParamTypes[0] != "bookId int64" {
		t.Fatalf("参数名/类型声明不对: %v", m.ParamTypes)
	}
	paths := map[string]bool{}
	for _, c := range reg.Commands() {
		paths[c.Path] = true
	}
	for _, p := range []string{"bookmark list", "record list"} {
		if !paths[p] {
			t.Fatalf("CLI 命令未注册: %s", p)
		}
	}

	// 位置参数：bookId, chapterIndex, chapterTitle, chapterPos, content, note。
	data, err := reg.Call(ctx, "Bookmark.Add", rawArgs(t, 3, 1, "第一章", 8, "摘录", "想法"))
	if err != nil {
		t.Fatalf("经注册表调用 Bookmark.Add 失败: %v", err)
	}
	item, ok := data.(BookmarkItem)
	if !ok {
		t.Fatalf("返回值类型不是 BookmarkItem: %T", data)
	}
	if item.BookID != 3 || item.ChapterIndex != 1 || item.Note != "想法" {
		t.Fatalf("位置参数错位: %+v", item)
	}

	// 省略尾参（note）也应可用。
	if _, err := reg.Call(ctx, "Bookmark.Add", rawArgs(t, 3, 2)); err != nil {
		t.Fatalf("省略尾参调用失败: %v", err)
	}

	if _, err := reg.Call(ctx, "Record.Append", rawArgs(t, 3, "书三", 1, "第一章")); err != nil {
		t.Fatalf("经注册表调用 Record.Append 失败: %v", err)
	}
	data, err = reg.Call(ctx, "Record.Stats", nil)
	if err != nil {
		t.Fatalf("经注册表调用 Record.Stats 失败: %v", err)
	}
	st, ok := data.(RecordStats)
	if !ok || st.Records != 1 {
		t.Fatalf("Record.Stats 返回值不对: %T %+v", data, data)
	}

	// 参数不足时给出 INVALID_ARGUMENT，而不是 panic 或 INTERNAL。
	if _, err := reg.Call(ctx, "Bookmark.Remove", nil); codeOf(t, err) != kernel.CodeInvalid {
		t.Fatalf("缺参应返回 INVALID_ARGUMENT，实际 %v", err)
	}
}

// rawArgs 把任意值序列化成控制面的位置参数数组。
func rawArgs(t *testing.T, vals ...any) []json.RawMessage {
	t.Helper()
	out := make([]json.RawMessage, 0, len(vals))
	for _, v := range vals {
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatalf("序列化参数失败: %v", err)
		}
		out = append(out, b)
	}
	return out
}
