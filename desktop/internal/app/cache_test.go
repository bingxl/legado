package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ── 测试替身 ────────────────────────────────────────────────────

// fakeBooks 是内存版书籍仓储，只实现缓存服务会用到的方法。
type fakeBooks struct {
	port.BookRepository
	mu    sync.Mutex
	books map[int64]*domain.Book
}

func newFakeBooks(books ...*domain.Book) *fakeBooks {
	m := make(map[int64]*domain.Book, len(books))
	for _, b := range books {
		m[b.ID] = b
	}
	return &fakeBooks{books: m}
}

func (f *fakeBooks) Get(_ context.Context, id int64) (*domain.Book, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	b, ok := f.books[id]
	if !ok {
		return nil, domain.ErrNotFound
	}
	return b, nil
}

func (f *fakeBooks) List(_ context.Context, groupID int64) ([]*domain.Book, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]*domain.Book, 0, len(f.books))
	for _, b := range f.books {
		if groupID != 0 && b.GroupID != groupID {
			continue
		}
		out = append(out, b)
	}
	return out, nil
}

// fakeChapters 是内存版目录仓储。
type fakeChapters struct {
	port.ChapterRepository
	list map[int64][]*domain.BookChapter
}

func newFakeChapters(bookID int64, count int) *fakeChapters {
	list := make([]*domain.BookChapter, 0, count)
	for i := 0; i < count; i++ {
		list = append(list, &domain.BookChapter{
			BookID: bookID,
			Index:  i,
			Title:  fmt.Sprintf("第%d章", i+1),
			URL:    fmt.Sprintf("https://example.com/book/%d/%d", bookID, i),
		})
	}
	return &fakeChapters{list: map[int64][]*domain.BookChapter{bookID: list}}
}

func (f *fakeChapters) List(_ context.Context, bookID int64) ([]*domain.BookChapter, error) {
	return f.list[bookID], nil
}

func (f *fakeChapters) Get(_ context.Context, bookID int64, index int) (*domain.BookChapter, error) {
	for _, c := range f.list[bookID] {
		if c.Index == index {
			return c, nil
		}
	}
	return nil, domain.ErrNotFound
}

// fakeCacheRepo 是内存版缓存仓储。
type fakeCacheRepo struct {
	mu   sync.Mutex
	data map[int64]map[int]*domain.CachedChapter
}

func newFakeCacheRepo() *fakeCacheRepo {
	return &fakeCacheRepo{data: make(map[int64]map[int]*domain.CachedChapter)}
}

func (f *fakeCacheRepo) Put(_ context.Context, c *domain.CachedChapter) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.data[c.BookID] == nil {
		f.data[c.BookID] = make(map[int]*domain.CachedChapter)
	}
	cp := *c
	f.data[c.BookID][c.Index] = &cp
	return nil
}

func (f *fakeCacheRepo) Get(_ context.Context, bookID int64, index int) (*domain.CachedChapter, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	c, ok := f.data[bookID][index]
	if !ok {
		return nil, domain.ErrNotFound
	}
	cp := *c
	return &cp, nil
}

func (f *fakeCacheRepo) List(_ context.Context, bookID int64) ([]*domain.CachedChapter, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]*domain.CachedChapter, 0, len(f.data[bookID]))
	for _, c := range f.data[bookID] {
		out = append(out, c)
	}
	return out, nil
}

func (f *fakeCacheRepo) Indexes(_ context.Context, bookID int64) ([]int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]int, 0, len(f.data[bookID]))
	for idx := range f.data[bookID] {
		out = append(out, idx)
	}
	return out, nil
}

func (f *fakeCacheRepo) BookStats(context.Context) ([]domain.CacheBookStat, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]domain.CacheBookStat, 0, len(f.data))
	for bookID, chapters := range f.data {
		st := domain.CacheBookStat{BookID: bookID, Chapters: len(chapters)}
		for _, c := range chapters {
			st.Size += c.Size
			if c.CreatedAt.After(st.UpdatedAt) {
				st.UpdatedAt = c.CreatedAt
			}
		}
		out = append(out, st)
	}
	return out, nil
}

func (f *fakeCacheRepo) Delete(_ context.Context, bookID int64, indexes []int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, idx := range indexes {
		delete(f.data[bookID], idx)
	}
	return nil
}

func (f *fakeCacheRepo) DeleteByBook(_ context.Context, bookID int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.data, bookID)
	return nil
}

func (f *fakeCacheRepo) DeleteAll(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.data = make(map[int64]map[int]*domain.CachedChapter)
	return nil
}

// fakeFetcher 模拟书源抓取；fail 置位后所有请求都失败（模拟断网）。
type fakeFetcher struct {
	port.SourceFetcher
	mu       sync.Mutex
	fail     bool
	images   []string
	hits     int
	blocking chan struct{} // 非 nil 时 GetContent 会等它关闭
}

func (f *fakeFetcher) GetContent(_ context.Context, _ *domain.BookSource, _ *domain.Book, ch *domain.BookChapter, _ string) (*port.ChapterContent, error) {
	if f.blocking != nil {
		<-f.blocking
	}
	f.mu.Lock()
	f.hits++
	fail := f.fail
	images := f.images
	f.mu.Unlock()
	if fail {
		return nil, errors.New("网络不可用")
	}
	if len(images) > 0 {
		return &port.ChapterContent{Title: ch.Title, Images: images}, nil
	}
	return &port.ChapterContent{Title: ch.Title, HTML: "<p>" + ch.Title + " 正文</p>"}, nil
}

func (f *fakeFetcher) setFail(v bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fail = v
}

// fakeSourceRepo 让 ContentProvider 能定位到书源。
type fakeSourceRepo struct{ port.BookSourceRepository }

func (fakeSourceRepo) FindByURL(context.Context, string) (*domain.BookSource, error) {
	return &domain.BookSource{ID: 1, Name: "测试源", URL: "https://example.com"}, nil
}

// fakeDownloader 返回固定字节的图片。
type fakeDownloader struct{ bytes []byte }

func (d fakeDownloader) Download(_ context.Context, rawURL, _ string) ([]byte, string, error) {
	if !strings.HasPrefix(rawURL, "https://img.example.com/") {
		return nil, "", errors.New("地址不可用")
	}
	return d.bytes, ".jpg", nil
}

// ── 测试辅助 ────────────────────────────────────────────────────

// newTestCache 组装一套缓存服务与它依赖的替身。
func newTestCache(t *testing.T, chapterCount int, opts ...func(*CacheDeps)) (*CacheService, *fakeCacheRepo, *fakeFetcher, *domain.Book) {
	t.Helper()

	book := &domain.Book{
		ID:            1,
		Name:          "测试小说",
		Kind:          domain.BookKindWeb,
		Format:        domain.BookFormatUnknown,
		Origin:        "https://example.com",
		TotalChapters: chapterCount,
	}
	books := newFakeBooks(book)
	chapters := newFakeChapters(book.ID, chapterCount)
	repo := newFakeCacheRepo()
	fetcher := &fakeFetcher{}

	content := NewContentProvider(books, chapters, fakeSourceRepo{}, nil, fetcher, repo)
	deps := CacheDeps{
		Root:     t.TempDir(),
		Books:    books,
		Chapters: chapters,
		Cache:    repo,
		Content:  content,
		Images:   fakeDownloader{bytes: []byte("image-bytes")},
	}
	for _, opt := range opts {
		opt(&deps)
	}
	return NewCacheService(deps), repo, fetcher, book
}

// waitJob 等任务进入终态。
func waitJob(t *testing.T, svc *CacheService, bookID int64) dto.CacheJob {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, job := range svc.Jobs() {
			if job.BookID != bookID {
				continue
			}
			if job.State != dto.CacheStateRunning {
				return job
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("缓存任务没有在超时内结束")
	return dto.CacheJob{}
}

// ── 用例 ────────────────────────────────────────────────────────

// 整本缓存：每章都落库，任务正常结束。
func TestCacheAllChapters(t *testing.T) {
	svc, repo, _, book := newTestCache(t, 3)

	if _, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil); err != nil {
		t.Fatalf("启动缓存失败: %v", err)
	}
	job := waitJob(t, svc, book.ID)
	if job.State != dto.CacheStateDone || job.Done != 3 || job.Failed != 0 {
		t.Fatalf("任务结果不符: %+v", job)
	}

	list, _ := repo.List(context.Background(), book.ID)
	if len(list) != 3 {
		t.Fatalf("应缓存 3 章，实际 %d", len(list))
	}
	c, err := repo.Get(context.Background(), book.ID, 1)
	if err != nil {
		t.Fatalf("读取缓存失败: %v", err)
	}
	if !strings.Contains(c.HTML, "第2章") {
		t.Fatalf("正文不正确: %q", c.HTML)
	}
	// 缓存必须记录当时的章节地址，目录变更时靠它判失效。
	if c.URL == "" {
		t.Fatal("缓存应记录章节地址")
	}
}

// 命中的缓存在断网后依然能读出来——这是「离线阅读」的全部意义。
func TestCachedChapterReadableOffline(t *testing.T) {
	svc, _, fetcher, book := newTestCache(t, 2)
	content := NewContentProvider(svc.books, svc.chapters, fakeSourceRepo{}, nil, fetcher, svc.cache)

	if _, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil); err != nil {
		t.Fatalf("启动缓存失败: %v", err)
	}
	waitJob(t, svc, book.ID)

	fetcher.setFail(true)
	got, err := content.Chapter(context.Background(), book.ID, 0)
	if err != nil {
		t.Fatalf("断网后读缓存失败: %v", err)
	}
	if !strings.Contains(got.HTML, "第1章") {
		t.Fatalf("缓存正文不正确: %q", got.HTML)
	}

	// 未缓存章节应当照常报错，而不是返回空内容。
	if _, err := content.Chapter(context.Background(), book.ID, 0+1); err != nil {
		t.Fatalf("第 2 章也在缓存里，应命中: %v", err)
	}
}

// 目录地址变化后旧缓存不再生效。
func TestStaleCacheIgnoredWhenChapterURLChanges(t *testing.T) {
	svc, repo, fetcher, book := newTestCache(t, 1)
	if err := repo.Put(context.Background(), &domain.CachedChapter{
		BookID: book.ID, Index: 0, Title: "旧章", URL: "https://example.com/old/0",
		HTML: "<p>旧内容</p>",
	}); err != nil {
		t.Fatalf("写入缓存失败: %v", err)
	}
	content := NewContentProvider(svc.books, svc.chapters, fakeSourceRepo{}, nil, fetcher, repo)

	got, err := content.Chapter(context.Background(), book.ID, 0)
	if err != nil {
		t.Fatalf("取正文失败: %v", err)
	}
	if strings.Contains(got.HTML, "旧内容") {
		t.Fatal("章节地址已变化，不应继续使用旧缓存")
	}
}

// 分卷标题不是正文，不参与缓存，否则任务里必然出现一批失败。
func TestCacheSkipsVolumeChapters(t *testing.T) {
	svc, repo, _, book := newTestCache(t, 3)
	svc.chapters.(*fakeChapters).list[book.ID][1].IsVolume = true

	if _, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil); err != nil {
		t.Fatalf("启动缓存失败: %v", err)
	}
	job := waitJob(t, svc, book.ID)
	if job.Total != 2 || job.Done != 2 {
		t.Fatalf("分卷应被跳过: %+v", job)
	}
	if _, err := repo.Get(context.Background(), book.ID, 1); !errors.Is(err, domain.ErrNotFound) {
		t.Fatal("分卷章节不应被缓存")
	}
}

// 剩余章节：从当前阅读位置开始，而不是从头。
func TestCacheRemainingFromProgress(t *testing.T) {
	svc, _, _, book := newTestCache(t, 5)
	book.DurChapterIndex = 3

	job, err := svc.Start(context.Background(), book.ID, dto.CacheScopeRemaining, nil)
	if err != nil {
		t.Fatalf("启动缓存失败: %v", err)
	}
	if job.Total != 2 {
		t.Fatalf("应从第 4 章缓存到结尾（2 章），got %d", job.Total)
	}
	waitJob(t, svc, book.ID)
}

// 只补缺失：已有的章节不再重复抓取。
func TestCacheMissingOnly(t *testing.T) {
	svc, repo, fetcher, book := newTestCache(t, 4)
	for _, idx := range []int{0, 2} {
		_ = repo.Put(context.Background(), &domain.CachedChapter{
			BookID: book.ID, Index: idx, Title: "已缓存", HTML: "<p>x</p>",
			URL: fmt.Sprintf("https://example.com/book/%d/%d", book.ID, idx),
		})
	}

	job, err := svc.Start(context.Background(), book.ID, dto.CacheScopeMissing, nil)
	if err != nil {
		t.Fatalf("启动缓存失败: %v", err)
	}
	if job.Total != 2 {
		t.Fatalf("应只补 2 章，got %d", job.Total)
	}
	waitJob(t, svc, book.ID)
	if hits := fetcher.hits; hits != 2 {
		t.Fatalf("只应抓取 2 次，实际 %d", hits)
	}
	if list, _ := repo.List(context.Background(), book.ID); len(list) != 4 {
		t.Fatalf("补齐后应有 4 章缓存，实际 %d", len(list))
	}
}

// 指定章节：去重、过滤不存在的序号。
func TestCacheChaptersScope(t *testing.T) {
	svc, repo, _, book := newTestCache(t, 3)

	job, err := svc.Start(context.Background(), book.ID, dto.CacheScopeChapters, []int{1, 1, 99})
	if err != nil {
		t.Fatalf("启动缓存失败: %v", err)
	}
	if job.Total != 1 {
		t.Fatalf("去重过滤后应只有 1 章，got %d", job.Total)
	}
	waitJob(t, svc, book.ID)
	if _, err := repo.Get(context.Background(), book.ID, 1); err != nil {
		t.Fatalf("第 2 章应已缓存: %v", err)
	}
}

// 漫画章节：图片下载到磁盘，缓存里存本地地址。
func TestCacheComicChapterDownloadsImages(t *testing.T) {
	svc, repo, fetcher, book := newTestCache(t, 1)
	fetcher.images = []string{
		"https://img.example.com/a/1.jpg",
		"https://img.example.com/a/2.jpg",
	}

	if _, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil); err != nil {
		t.Fatalf("启动缓存失败: %v", err)
	}
	waitJob(t, svc, book.ID)

	c, err := repo.Get(context.Background(), book.ID, 0)
	if err != nil {
		t.Fatalf("读取缓存失败: %v", err)
	}
	if len(c.Images) != 2 {
		t.Fatalf("应缓存 2 张图，实际 %d", len(c.Images))
	}
	for i, u := range c.Images {
		if !strings.HasPrefix(u, "/local/cache/chapter/") {
			t.Fatalf("第 %d 张图片地址应为本地地址，got %q", i+1, u)
		}
		rel := strings.TrimPrefix(u, "/local/")
		path := filepath.Join(svc.root, filepath.FromSlash(rel))
		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("图片没有落盘: %v", err)
		}
		if info.Size() == 0 {
			t.Fatal("图片文件为空")
		}
	}
	if c.Size != 22 { // 2 张 × "image-bytes"(11 字节)
		t.Fatalf("占用字节应为 22，got %d", c.Size)
	}
}

// 图片下载失败时这一章整体记为失败，且不留半份残缺缓存。
func TestCacheComicFailureLeavesNoPartial(t *testing.T) {
	svc, repo, fetcher, book := newTestCache(t, 1)
	fetcher.images = []string{"https://img.example.com/a/1.jpg", "https://bad.example.org/x.jpg"}

	if _, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil); err != nil {
		t.Fatalf("启动缓存失败: %v", err)
	}
	job := waitJob(t, svc, book.ID)
	if job.Failed != 1 || job.Done != 0 {
		t.Fatalf("应记 1 章失败: %+v", job)
	}
	if _, err := repo.Get(context.Background(), book.ID, 0); !errors.Is(err, domain.ErrNotFound) {
		t.Fatal("失败章节不应留下缓存记录")
	}
	dir := filepath.Join(svc.root, "cache", "chapter", "1", "0")
	if _, err := os.Stat(dir); err == nil {
		t.Fatal("失败章节不应留下图片目录")
	}
}

// 删除单章缓存要同时删掉磁盘图片目录。
func TestDeleteChaptersRemovesFiles(t *testing.T) {
	svc, repo, fetcher, book := newTestCache(t, 2)
	fetcher.images = []string{"https://img.example.com/a/1.jpg"}
	if _, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil); err != nil {
		t.Fatalf("启动缓存失败: %v", err)
	}
	waitJob(t, svc, book.ID)

	dir := filepath.Join(svc.root, "cache", "chapter", "1", "0")
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("图片目录应存在: %v", err)
	}
	if err := svc.Delete(context.Background(), book.ID, []int{0}); err != nil {
		t.Fatalf("删除缓存失败: %v", err)
	}
	if _, err := repo.Get(context.Background(), book.ID, 0); !errors.Is(err, domain.ErrNotFound) {
		t.Fatal("缓存记录应已删除")
	}
	if _, err := os.Stat(dir); err == nil {
		t.Fatal("图片目录应已删除")
	}
	// 第 2 章还在。
	if _, err := repo.Get(context.Background(), book.ID, 1); err != nil {
		t.Fatalf("未删除的章节不应受影响: %v", err)
	}
}

// 本地书不需要缓存。
func TestCacheRejectsLocalBook(t *testing.T) {
	svc, _, _, book := newTestCache(t, 2)
	book.Kind = domain.BookKindLocal

	_, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil)
	if !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("本地书应被拒绝，got %v", err)
	}
}

// 同一本书不允许并发两个任务；取消后可以重新开始。
func TestCacheSingleJobPerBook(t *testing.T) {
	svc, _, fetcher, book := newTestCache(t, 2)
	release := make(chan struct{})
	fetcher.blocking = release

	if _, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil); err != nil {
		t.Fatalf("首次启动失败: %v", err)
	}
	if _, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil); err == nil {
		t.Fatal("同一本书不应允许第二个任务")
	}

	if err := svc.Cancel(book.ID); err != nil {
		t.Fatalf("取消失败: %v", err)
	}
	close(release)

	job := waitJob(t, svc, book.ID)
	if job.State != dto.CacheStateCanceled {
		t.Fatalf("取消后状态应为 canceled，got %s", job.State)
	}

	// 任务结束后可以重新启动（此时章数仍是 2，允许重试）。
	fetcher.blocking = nil
	if _, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil); err != nil {
		t.Fatalf("取消后应可重新启动: %v", err)
	}
	waitJob(t, svc, book.ID)
}

// 统计与列表：按书聚合的章数与大小要正确。
func TestCacheStatsAndBooks(t *testing.T) {
	svc, _, _, book := newTestCache(t, 2)

	if _, err := svc.Start(context.Background(), book.ID, dto.CacheScopeAll, nil); err != nil {
		t.Fatalf("启动缓存失败: %v", err)
	}
	waitJob(t, svc, book.ID)

	stats, err := svc.Stats(context.Background())
	if err != nil {
		t.Fatalf("统计失败: %v", err)
	}
	if stats.Books != 1 || stats.Chapters != 2 || stats.Size <= 0 {
		t.Fatalf("统计结果不符: %+v", stats)
	}

	books, err := svc.Books(context.Background())
	if err != nil {
		t.Fatalf("查询缓存书籍失败: %v", err)
	}
	if len(books) != 1 || books[0].Name != "测试小说" || books[0].CachedChapters != 2 {
		t.Fatalf("缓存列表不符: %+v", books)
	}

	chapters, err := svc.Chapters(context.Background(), book.ID)
	if err != nil {
		t.Fatalf("查询缓存章节失败: %v", err)
	}
	if len(chapters) != 2 || chapters[0].Title != "第1章" {
		t.Fatalf("章节明细不符: %+v", chapters)
	}

	// 清空后一切都归零。
	if err := svc.Clear(context.Background()); err != nil {
		t.Fatalf("清空缓存失败: %v", err)
	}
	stats, _ = svc.Stats(context.Background())
	if stats.Books != 0 || stats.Chapters != 0 {
		t.Fatalf("清空后统计应为空: %+v", stats)
	}
	if _, err := os.Stat(filepath.Join(svc.root, "cache", "chapter")); err == nil {
		t.Fatal("清空后图片目录应不存在")
	}
}
