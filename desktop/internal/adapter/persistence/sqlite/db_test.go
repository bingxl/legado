package sqlite

import (
	"context"
	"errors"
	"testing"

	"github.com/legado/desktop/internal/domain"
)

// newTestDB 创建一个内存数据库用于测试。
func newTestDB(t *testing.T) *DB {
	t.Helper()
	db, err := Open("file:testdb?mode=memory&cache=shared")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func TestOpen_AppliesMigrations(t *testing.T) {
	db := newTestDB(t)

	var n int
	if err := db.db.QueryRow(`SELECT COUNT(1) FROM schema_version`).Scan(&n); err != nil {
		t.Fatalf("查询迁移版本失败: %v", err)
	}
	if n == 0 {
		t.Fatal("迁移未执行：schema_version 为空")
	}

	// 内置分组应已写入。
	groups, err := NewBookGroupRepo(db).List(context.Background())
	if err != nil {
		t.Fatalf("列出分组失败: %v", err)
	}
	if len(groups) == 0 {
		t.Fatal("内置分组缺失")
	}
}

func TestBookRepo_CRUD(t *testing.T) {
	ctx := context.Background()
	db := newTestDB(t)
	repo := NewBookRepo(db)

	b := &domain.Book{
		Name:    "测试书籍",
		Author:  "作者",
		Kind:    domain.BookKindLocal,
		Format:  domain.BookFormatEPUB,
		Origin:  "local",
		BookURL: "/tmp/test.epub",
	}
	if err := repo.Create(ctx, b); err != nil {
		t.Fatalf("创建书籍失败: %v", err)
	}
	if b.ID == 0 {
		t.Fatal("创建后未回填 ID")
	}

	got, err := repo.Get(ctx, b.ID)
	if err != nil {
		t.Fatalf("读取书籍失败: %v", err)
	}
	if got.Name != b.Name {
		t.Fatalf("书名不符: 期望 %q, 实际 %q", b.Name, got.Name)
	}

	// 按 URL 定位，用于导入去重。
	found, err := repo.FindByURL(ctx, "local", "/tmp/test.epub")
	if err != nil {
		t.Fatalf("按 URL 查找失败: %v", err)
	}
	if found.ID != b.ID {
		t.Fatalf("FindByURL 返回了错误的书籍: %d", found.ID)
	}

	// 重复插入同 origin+url 应报已存在。
	if err := repo.Create(ctx, &domain.Book{Name: "重复", Origin: "local", BookURL: "/tmp/test.epub"}); err == nil {
		t.Fatal("重复书籍应当报错")
	}

	got.TotalChapters = 10
	got.DurChapterIndex = 3
	if err := repo.Update(ctx, got); err != nil {
		t.Fatalf("更新书籍失败: %v", err)
	}
	updated, _ := repo.Get(ctx, b.ID)
	if updated.TotalChapters != 10 || updated.ReadPercent() != 40 {
		t.Fatalf("更新失败或进度计算错误: chapters=%d percent=%d",
			updated.TotalChapters, updated.ReadPercent())
	}

	if err := repo.UpdateProgress(ctx, b.ID, 5, "第五章", 0); err != nil {
		t.Fatalf("更新进度失败: %v", err)
	}
	updated, _ = repo.Get(ctx, b.ID)
	if updated.DurChapterIndex != 5 || updated.LastReadAt.IsZero() {
		t.Fatalf("进度更新失败: index=%d lastRead=%v", updated.DurChapterIndex, updated.LastReadAt)
	}

	if err := repo.Delete(ctx, b.ID); err != nil {
		t.Fatalf("删除书籍失败: %v", err)
	}
	if _, err := repo.Get(ctx, b.ID); err != domain.ErrNotFound {
		t.Fatalf("删除后应返回 ErrNotFound，实际: %v", err)
	}
}

func TestChapterRepo_ReplaceAll(t *testing.T) {
	ctx := context.Background()
	db := newTestDB(t)
	books := NewBookRepo(db)
	chapters := NewChapterRepo(db)

	b := &domain.Book{Name: "书", Origin: "local", BookURL: "/a/b.epub", Kind: domain.BookKindLocal}
	if err := books.Create(ctx, b); err != nil {
		t.Fatalf("创建书籍失败: %v", err)
	}

	in := []*domain.BookChapter{
		{Index: 0, Title: "第一章"},
		{Index: 1, Title: "第二章"},
	}
	// ReplaceAll 应在事务中执行，这里直接调用亦可验证逻辑。
	if err := db.Do(ctx, func(ctx context.Context) error {
		return chapters.ReplaceAll(ctx, b.ID, in)
	}); err != nil {
		t.Fatalf("替换章节失败: %v", err)
	}

	list, err := chapters.List(ctx, b.ID)
	if err != nil {
		t.Fatalf("列出章节失败: %v", err)
	}
	if len(list) != 2 || list[0].Title != "第一章" {
		t.Fatalf("章节列表不符: %+v", list)
	}

	// 再次替换应覆盖旧数据而非追加。
	if err := db.Do(ctx, func(ctx context.Context) error {
		return chapters.ReplaceAll(ctx, b.ID, []*domain.BookChapter{{Index: 0, Title: "新第一章"}})
	}); err != nil {
		t.Fatalf("二次替换失败: %v", err)
	}
	list, _ = chapters.List(ctx, b.ID)
	if len(list) != 1 || list[0].Title != "新第一章" {
		t.Fatalf("二次替换结果不符: %+v", list)
	}
}

func TestBookSourceRepo_DuplicateURL(t *testing.T) {
	ctx := context.Background()
	db := newTestDB(t)
	repo := NewBookSourceRepo(db)

	src := &domain.BookSource{
		Name:    "源A",
		URL:     "https://example.com/s.json",
		Enabled: true,
		Raw:     `{"bookSourceUrl":"https://example.com/s.json"}`,
	}
	if err := repo.Create(ctx, src); err != nil {
		t.Fatalf("创建书源失败: %v", err)
	}
	// 仓储会为领域错误附加上下文，因此用 errors.Is 判定而非直接比较。
	if err := repo.Create(ctx, &domain.BookSource{Name: "源B", URL: "https://example.com/s.json"}); !errors.Is(err, domain.ErrAlreadyExists) {
		t.Fatalf("重复书源应返回 ErrAlreadyExists，实际: %v", err)
	}

	enabled, err := repo.ListEnabled(ctx)
	if err != nil || len(enabled) != 1 {
		t.Fatalf("列出启用书源失败: %v, count=%d", err, len(enabled))
	}
}

func TestSettingsStore(t *testing.T) {
	ctx := context.Background()
	db := newTestDB(t)
	store := NewSettingsStore(db)

	if _, err := store.Get(ctx, "missing"); err != domain.ErrNotFound {
		t.Fatalf("缺失配置应返回 ErrNotFound，实际: %v", err)
	}
	if err := store.Set(ctx, "k", "v"); err != nil {
		t.Fatalf("写入配置失败: %v", err)
	}
	v, err := store.Get(ctx, "k")
	if err != nil || v != "v" {
		t.Fatalf("读取配置失败: %v, value=%q", err, v)
	}
}
