package app

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// memSourceRepo 是内存版书源仓储，只实现导入路径用到的方法。
// 其余方法靠嵌入接口留空：路径一旦变化调到未实现的方法会 panic，而不是静默通过。
type memSourceRepo struct {
	port.BookSourceRepository
	items map[string]*domain.BookSource // key = bookSourceUrl
	seq   int64
}

func newMemSourceRepo() *memSourceRepo {
	return &memSourceRepo{items: make(map[string]*domain.BookSource)}
}

func (r *memSourceRepo) FindByURL(_ context.Context, url string) (*domain.BookSource, error) {
	if s, ok := r.items[url]; ok {
		return s, nil
	}
	return nil, domain.ErrNotFound
}

func (r *memSourceRepo) Create(_ context.Context, s *domain.BookSource) error {
	r.seq++
	s.ID = r.seq
	r.items[s.URL] = s
	return nil
}

func (r *memSourceRepo) Update(_ context.Context, s *domain.BookSource) error {
	r.items[s.URL] = s
	return nil
}

func (r *memSourceRepo) List(context.Context, string) ([]*domain.BookSource, error) {
	out := make([]*domain.BookSource, 0, len(r.items))
	for _, s := range r.items {
		out = append(out, s)
	}
	return out, nil
}

func newImportTestService(repo *memSourceRepo) *SourceService {
	return NewSourceService(SourceDeps{Sources: repo})
}

// 一份真实形态的书源文件：顶层是数组，含两个书源。
const multiSourceJSON = `[
  {"bookSourceName":"源甲","bookSourceUrl":"https://a.example.com","bookSourceGroup":"测试","searchUrl":"https://a.example.com/s?q=@key"},
  {"bookSourceName":"源乙","bookSourceUrl":"https://b.example.com","searchUrl":"https://b.example.com/s?q=@key"}
]`

func TestImportFromURLImportsAllSources(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("User-Agent"); got == "" {
			t.Errorf("请求没有带 User-Agent，部分站点会直接 403")
		}
		_, _ = w.Write([]byte(multiSourceJSON))
	}))
	defer srv.Close()

	repo := newMemSourceRepo()
	svc := newImportTestService(repo)

	res, err := svc.ImportFromURL(context.Background(), srv.URL+"/bookSources.json", true)
	if err != nil {
		t.Fatalf("ImportFromURL 返回错误: %v", err)
	}
	if res.Imported != 2 || res.Updated != 0 {
		t.Fatalf("期望新增 2 条、更新 0 条，实际新增 %d、更新 %d", res.Imported, res.Updated)
	}
	if len(repo.items) != 2 {
		t.Fatalf("入库条数应为 2，实际 %d", len(repo.items))
	}
	if got := repo.items["https://a.example.com"]; got == nil || got.Name != "源甲" {
		t.Fatalf("第一个书源未正确入库: %+v", got)
	}
}

func TestImportFromURLOverwriteSemantics(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(multiSourceJSON))
	}))
	defer srv.Close()

	repo := newMemSourceRepo()
	svc := newImportTestService(repo)

	if _, err := svc.ImportFromURL(context.Background(), srv.URL, true); err != nil {
		t.Fatalf("首次导入失败: %v", err)
	}

	// 第二次不覆盖：同 URL 应全部跳过，不产生新增。
	res, err := svc.ImportFromURL(context.Background(), srv.URL, false)
	if err != nil {
		t.Fatalf("二次导入失败: %v", err)
	}
	if res.Imported != 0 || res.Updated != 0 || res.Skipped != 2 {
		t.Fatalf("不覆盖时期望 跳过 2 条，实际 %+v", res)
	}

	// 第三次覆盖：应全部更新。
	res, err = svc.ImportFromURL(context.Background(), srv.URL, true)
	if err != nil {
		t.Fatalf("三次导入失败: %v", err)
	}
	if res.Updated != 2 || res.Imported != 0 {
		t.Fatalf("覆盖时期望 更新 2 条，实际 %+v", res)
	}
}

func TestImportFromURLRejectsBadInput(t *testing.T) {
	repo := newMemSourceRepo()
	svc := newImportTestService(repo)

	cases := []struct {
		name string
		url  string
		want error
	}{
		{"空地址", "   ", domain.ErrInvalidArgument},
		// 只放行 http/https：file:// 会让后端读本机任意文件。
		{"file 协议", "file:///C:/Windows/win.ini", domain.ErrInvalidArgument},
		{"非 URL", "not-a-url", domain.ErrInvalidArgument},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := svc.ImportFromURL(context.Background(), c.url, true)
			if !errors.Is(err, c.want) {
				t.Fatalf("期望错误 %v，实际 %v", c.want, err)
			}
		})
	}
}

func TestImportFromURLHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	svc := newImportTestService(newMemSourceRepo())
	_, err := svc.ImportFromURL(context.Background(), srv.URL, true)
	if !errors.Is(err, domain.ErrRemoteFailed) {
		t.Fatalf("非 2xx 应报 ErrRemoteFailed，实际 %v", err)
	}
}

// 拉下来的正文不是书源（例如给成了网页）时要报解析失败，并带上地址。
func TestImportFromURLNonSourceBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("<html><body>这不是书源</body></html>"))
	}))
	defer srv.Close()

	svc := newImportTestService(newMemSourceRepo())
	_, err := svc.ImportFromURL(context.Background(), srv.URL, true)
	if !errors.Is(err, domain.ErrParseFailed) {
		t.Fatalf("非书源正文应报 ErrParseFailed，实际 %v", err)
	}
}
