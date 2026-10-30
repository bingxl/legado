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
}

func (b *stubBooks) FindByURL(context.Context, string, string) (*domain.Book, error) {
	return nil, domain.ErrNotFound
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
