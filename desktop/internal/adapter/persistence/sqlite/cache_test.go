package sqlite

import (
	"context"
	"errors"
	"testing"

	"github.com/legado/desktop/internal/domain"
)

// TestChapterCacheRepo_RoundTrip 校验迁移建表、写入覆盖、读取与聚合。
func TestChapterCacheRepo_RoundTrip(t *testing.T) {
	ctx := context.Background()
	db := newTestDB(t)
	books := NewBookRepo(db)
	repo := NewChapterCacheRepo(db)

	book := &domain.Book{
		Name:    "缓存测试书",
		Kind:    domain.BookKindWeb,
		Format:  domain.BookFormatUnknown,
		Origin:  "https://example.com",
		BookURL: "https://example.com/book/1",
	}
	if err := books.Create(ctx, book); err != nil {
		t.Fatalf("创建书籍失败: %v", err)
	}

	// 文本章节。
	text := &domain.CachedChapter{
		BookID: book.ID, Index: 0, Title: "第1章", URL: "https://example.com/1",
		HTML: "<p>正文</p>", Size: 10,
	}
	if err := repo.Put(ctx, text); err != nil {
		t.Fatalf("写入文本缓存失败: %v", err)
	}
	// 漫画章节：图片地址列表要能原样往返。
	comic := &domain.CachedChapter{
		BookID: book.ID, Index: 1, Title: "第2话", URL: "https://example.com/2",
		Images: []string{"/local/cache/chapter/1/1/001.jpg", "/local/cache/chapter/1/1/002.jpg"},
		Size:   2048,
	}
	if err := repo.Put(ctx, comic); err != nil {
		t.Fatalf("写入图片缓存失败: %v", err)
	}

	got, err := repo.Get(ctx, book.ID, 1)
	if err != nil {
		t.Fatalf("读取缓存失败: %v", err)
	}
	if len(got.Images) != 2 || got.Size != 2048 || got.CreatedAt.IsZero() {
		t.Fatalf("图片缓存往返不一致: %+v", got)
	}

	// 覆盖写入：同一 (书, 序号) 只保留最新一条。
	text.HTML = "<p>新正文</p>"
	text.Size = 99
	if err := repo.Put(ctx, text); err != nil {
		t.Fatalf("覆盖写入失败: %v", err)
	}
	got, _ = repo.Get(ctx, book.ID, 0)
	if got.HTML != "<p>新正文</p>" || got.Size != 99 {
		t.Fatalf("覆盖写入未生效: %+v", got)
	}

	stats, err := repo.BookStats(ctx)
	if err != nil {
		t.Fatalf("聚合统计失败: %v", err)
	}
	if len(stats) != 1 || stats[0].Chapters != 2 || stats[0].Size != 2048+99 {
		t.Fatalf("聚合结果不符: %+v", stats)
	}
	if stats[0].UpdatedAt.IsZero() {
		t.Fatal("聚合时间未解析")
	}

	indexes, _ := repo.Indexes(ctx, book.ID)
	if len(indexes) != 2 || indexes[0] != 0 || indexes[1] != 1 {
		t.Fatalf("索引列表不符: %v", indexes)
	}

	// 删除单章。
	if err := repo.Delete(ctx, book.ID, []int{0}); err != nil {
		t.Fatalf("删除缓存失败: %v", err)
	}
	if _, err := repo.Get(ctx, book.ID, 0); !errors.Is(err, domain.ErrNotFound) {
		t.Fatal("删除后仍能读到缓存")
	}

	// 删书级联清理缓存行。
	if err := books.Delete(ctx, book.ID); err != nil {
		t.Fatalf("删除书籍失败: %v", err)
	}
	if left, _ := repo.List(ctx, book.ID); len(left) != 0 {
		t.Fatalf("删书后缓存应被级联清理，剩 %d 条", len(left))
	}
}
