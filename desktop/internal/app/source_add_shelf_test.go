package app

import (
	"context"
	"errors"
	"testing"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// 这些桩只用「嵌入接口」的办法实现被调用的方法，其余方法留空，
// 一旦被测代码路径变化、调到了没实现的方法，会立刻 panic 而不是静默通过。

type stubSources struct {
	port.BookSourceRepository
	src *domain.BookSource
}

func (s stubSources) Get(context.Context, int64) (*domain.BookSource, error) {
	return s.src, nil
}

type stubBooks struct {
	port.BookRepository
	created *domain.Book
	// existing 非空时 FindByURL 返回它（模拟书已在库：可能是试读，也可能已入架）。
	existing *domain.Book
	// promoted 记录 SetInShelf 的调用，用于断言「试读转正」发生了。
	promoted []int64
}

func (b *stubBooks) FindByURL(context.Context, string, string) (*domain.Book, error) {
	if b.existing != nil {
		return b.existing, nil
	}
	return nil, domain.ErrNotFound
}

func (b *stubBooks) SetInShelf(_ context.Context, id int64, inShelf bool) error {
	b.promoted = append(b.promoted, id)
	if b.existing != nil {
		b.existing.Previewing = !inShelf
	}
	return nil
}

func (b *stubBooks) Create(_ context.Context, book *domain.Book) error {
	if book.Name == "" {
		return errors.New("书名不能为空")
	}
	book.ID = 7
	b.created = book
	return nil
}

type stubChapters struct{ port.ChapterRepository }

func (stubChapters) ReplaceAll(context.Context, int64, []*domain.BookChapter) error { return nil }

// stubFetcher 模拟「详情页规则取不到书名」的书源：
// 引擎的 analyzeBookInfo 在规则为空时保留 book 上已有的值，这里照此行为实现。
type stubFetcher struct {
	port.SourceFetcher
	seenName     string
	seenVariable string
}

func (f *stubFetcher) GetBookInfo(_ context.Context, _ *domain.BookSource, b *domain.Book) (*domain.Book, []*domain.BookChapter, error) {
	f.seenName = b.Name
	f.seenVariable = b.Variable
	return b, []*domain.BookChapter{{Index: 0, Title: "第一章"}}, nil
}

func newTestSourceService(books *stubBooks, fetcher *stubFetcher) *SourceService {
	return NewSourceService(SourceDeps{
		Sources:  stubSources{src: &domain.BookSource{ID: 20, Name: "ESJ Zone", URL: "https://example.com"}},
		Books:    books,
		Chapters: stubChapters{},
		Fetcher:  fetcher,
	})
}

// 列表页已知的书名要传进 AddToShelf，否则详情规则取不到书名时会落库失败。
func TestAddToShelfKeepsListName(t *testing.T) {
	books := &stubBooks{}
	fetcher := &stubFetcher{}
	svc := newTestSourceService(books, fetcher)

	brief, err := svc.AddToShelf(context.Background(), 20, "https://example.com/book/1", " 转生史莱姆 ", "伏濑", "", 0)
	if err != nil {
		t.Fatalf("AddToShelf 出错: %v", err)
	}
	if fetcher.seenName != "转生史莱姆" {
		t.Fatalf("预填书名没有传给抓取器，got %q", fetcher.seenName)
	}
	if brief.ID != 7 || brief.Name != "转生史莱姆" || brief.Author != "伏濑" {
		t.Fatalf("落库结果不符: %+v", brief)
	}
	if books.created == nil || books.created.Kind != domain.BookKindWeb {
		t.Fatalf("应落库为网络书: %+v", books.created)
	}
}

// 列表页和详情页都拿不到书名时，要给出可定位的报错，而不是抛数据库校验错误。
func TestAddToShelfWithoutAnyName(t *testing.T) {
	books := &stubBooks{}
	svc := newTestSourceService(books, &stubFetcher{})

	_, err := svc.AddToShelf(context.Background(), 20, "https://example.com/book/2", "", "", "", 0)
	if err == nil {
		t.Fatal("书名为空时应当报错")
	}
	if !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("错误类型应为 ErrInvalidArgument，got %v", err)
	}
	if books.created != nil {
		t.Fatal("不应落库")
	}
}

// 列表页 @put 出来的变量要一路带到书籍上：目录/正文规则里的 @get 靠它取值，
// 丢了就会请求到 "…/book//volumes" 这种空参数地址（17k小说 的典型症状）。
func TestAddToShelfKeepsListVariable(t *testing.T) {
	books := &stubBooks{}
	fetcher := &stubFetcher{}
	svc := newTestSourceService(books, fetcher)

	vars := `{"book":"12345"}`
	if _, err := svc.AddToShelf(context.Background(), 20, "https://example.com/book/3", "书名", "作者", vars, 0); err != nil {
		t.Fatalf("AddToShelf 出错: %v", err)
	}
	if fetcher.seenVariable != vars {
		t.Fatalf("变量没有传给抓取器，got %q", fetcher.seenVariable)
	}
	if books.created == nil || books.created.Variable != vars {
		t.Fatalf("变量没有落库: %+v", books.created)
	}
}

// 发现/搜索点开书只试读（不进书架），用户在详情页/阅读器点「加入书架」
// 时走的还是 AddToShelf：已存在的试读书要就地转正，而不是再插一条。
func TestAddToShelfPromotesPreviewBook(t *testing.T) {
	existing := &domain.Book{ID: 9, Name: "试读的书", Previewing: true}
	books := &stubBooks{existing: existing}
	svc := newTestSourceService(books, &stubFetcher{})

	brief, err := svc.AddToShelf(context.Background(), 20, "https://example.com/book/9", "", "", "", 0)
	if err != nil {
		t.Fatalf("AddToShelf 出错: %v", err)
	}
	if brief.ID != 9 || !brief.InShelf {
		t.Fatalf("应把已有的试读书转正: %+v", brief)
	}
	if len(books.promoted) != 1 || books.promoted[0] != 9 {
		t.Fatalf("没有更新书架标记: %v", books.promoted)
	}
	if books.created != nil {
		t.Fatal("已存在的书不应重复落库")
	}
}

// PreviewBook 遇到已在书架的书，不能把它降级成试读。
func TestPreviewBookKeepsExistingShelfState(t *testing.T) {
	existing := &domain.Book{ID: 9, Name: "已在书架"}
	books := &stubBooks{existing: existing}
	svc := newTestSourceService(books, &stubFetcher{})

	brief, err := svc.PreviewBook(context.Background(), 20, "https://example.com/book/9", "", "", "")
	if err != nil {
		t.Fatalf("PreviewBook 出错: %v", err)
	}
	if !brief.InShelf {
		t.Fatalf("已在书架的书不能被当成试读: %+v", brief)
	}
	if len(books.promoted) != 0 {
		t.Fatalf("不应改写书架标记: %v", books.promoted)
	}
}

// 新书走 PreviewBook 时以试读状态落库：书架里看不到，但目录已经抓好，
// 用户点「加入书架」后可以立刻接着读。
func TestPreviewBookCreatesPreviewing(t *testing.T) {
	books := &stubBooks{}
	svc := newTestSourceService(books, &stubFetcher{})

	brief, err := svc.PreviewBook(context.Background(), 20, "https://example.com/book/10", "书名", "作者", "")
	if err != nil {
		t.Fatalf("PreviewBook 出错: %v", err)
	}
	if books.created == nil || !books.created.Previewing {
		t.Fatalf("新书应以试读状态落库: %+v", books.created)
	}
	if brief.InShelf {
		t.Fatalf("试读书不应出现在书架: %+v", brief)
	}
}
