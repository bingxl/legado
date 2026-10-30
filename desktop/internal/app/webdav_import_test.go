package app

import (
	"context"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ── 内存替身 ────────────────────────────────────────────────────────────

// memSettings 固定返回一份配置。
type memSettings struct {
	port.SettingsStore
	raw string
}

func (m memSettings) Get(context.Context, string) (string, error) { return m.raw, nil }
func (m memSettings) Set(context.Context, string, string) error   { return nil }

// memDAV 是内存版 WebDAV 客户端：files 的键是完整远端路径。
type memDAV struct {
	mu    sync.Mutex
	files map[string]string
	// chunkDelay 让下载变慢，用于测试取消；为 0 时一次性读完。
	chunkDelay time.Duration
	// listCalls 记录 List 调用，便于断言递归行为。
	listCalls []string
}

func newMemDAV(files map[string]string) *memDAV {
	return &memDAV{files: files}
}

func (m *memDAV) List(ctx context.Context, dir string) ([]port.WebDAVEntry, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.listCalls = append(m.listCalls, dir)

	dir = strings.TrimSuffix(dir, "/")
	subDirs := map[string]struct{}{}
	out := make([]port.WebDAVEntry, 0, 4)
	for full, content := range m.files {
		if path.Dir(full) == dir {
			out = append(out, port.WebDAVEntry{
				Path:    full,
				Name:    path.Base(full),
				Size:    int64(len(content)),
				ModTime: time.Unix(1700000000, 0),
			})
			continue
		}
		if strings.HasPrefix(full, dir+"/") {
			rest := strings.TrimPrefix(full, dir+"/")
			if i := strings.Index(rest, "/"); i > 0 {
				subDirs[rest[:i]] = struct{}{}
			}
		}
	}
	for name := range subDirs {
		out = append(out, port.WebDAVEntry{
			Path:    dir + "/" + name,
			Name:    name,
			IsDir:   true,
			ModTime: time.Unix(1700000000, 0),
		})
	}
	return out, nil
}

func (m *memDAV) Stat(ctx context.Context, p string) (*port.WebDAVEntry, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if content, ok := m.files[p]; ok {
		return &port.WebDAVEntry{
			Path:    p,
			Name:    path.Base(p),
			Size:    int64(len(content)),
			ModTime: time.Unix(1700000000, 0),
		}, nil
	}
	for full := range m.files {
		if strings.HasPrefix(full, p+"/") {
			return &port.WebDAVEntry{Path: p, Name: path.Base(p), IsDir: true, ModTime: time.Unix(1700000000, 0)}, nil
		}
	}
	return nil, domain.ErrNotFound
}

func (m *memDAV) Download(ctx context.Context, p string) (io.ReadCloser, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	content, ok := m.files[p]
	delay := m.chunkDelay
	m.mu.Unlock()
	if !ok {
		return nil, domain.ErrNotFound
	}
	return &slowReadCloser{ctx: ctx, data: []byte(content), delay: delay}, nil
}

func (m *memDAV) Upload(context.Context, string, io.Reader) error { return nil }
func (m *memDAV) MkdirAll(context.Context, string) error          { return nil }
func (m *memDAV) Delete(context.Context, string) error            { return nil }

// slowReadCloser 每次读一小块并可延迟，模拟慢速网络。
type slowReadCloser struct {
	ctx   context.Context
	data  []byte
	off   int
	delay time.Duration
}

func (r *slowReadCloser) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	if r.off >= len(r.data) {
		return 0, io.EOF
	}
	if r.delay > 0 {
		time.Sleep(r.delay)
	}
	n := len(p)
	if n > 32 {
		n = 32
	}
	if r.off+n > len(r.data) {
		n = len(r.data) - r.off
	}
	copy(p, r.data[r.off:r.off+n])
	r.off += n
	return n, nil
}

func (r *slowReadCloser) Close() error { return nil }

// memDAVFactory 始终返回同一个内存客户端。
type memDAVFactory struct{ client port.WebDAVClient }

func (f memDAVFactory) New(domain.WebDAVConfig) (port.WebDAVClient, error) { return f.client, nil }

// fakeImporter 记录被导入的本地路径。
type fakeImporter struct {
	mu    sync.Mutex
	paths []string
	fail  map[string]bool
}

func (f *fakeImporter) ImportLocalFiles(_ context.Context, paths []string, _ int64) (*dto.ImportResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	res := &dto.ImportResult{Imported: make([]dto.BookBrief, 0, len(paths))}
	for _, p := range paths {
		if f.fail[filepath.Base(p)] {
			res.Failed = append(res.Failed, dto.ImportFailure{Path: p, Reason: "解析失败"})
			continue
		}
		f.paths = append(f.paths, p)
		res.Imported = append(res.Imported, dto.BookBrief{Name: strings.TrimSuffix(filepath.Base(p), filepath.Ext(p))})
	}
	return res, nil
}

func (f *fakeImporter) imported() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.paths...)
}

// ── 夹具 ────────────────────────────────────────────────────────────────

func newImportFixture(t *testing.T, files map[string]string) (*WebDAVService, *memDAV, *fakeImporter, string) {
	t.Helper()
	dav := newMemDAV(files)
	imp := &fakeImporter{fail: map[string]bool{}}
	root := t.TempDir()
	svc := NewWebDAVService(
		memSettings{raw: `{"url":"http://dav.local","rootPath":"legado-desktop"}`},
		memDAVFactory{client: dav},
		nil,
		"",
	).WithBookImport(root, imp)
	return svc, dav, imp, root
}

// waitIdle 轮询直到任务结束。
func waitIdle(t *testing.T, svc *WebDAVService) dto.WebDAVImportJob {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		job := svc.ImportStatus()
		if job.State != dto.WebDAVImportRunning {
			return job
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("导入任务超时未结束: %+v", svc.ImportStatus())
	return dto.WebDAVImportJob{}
}

// ── 用例 ────────────────────────────────────────────────────────────────

// 扫描要递归进子目录、只收书籍扩展名、跳过无关文件与隐藏目录。
func TestWebDAVScanBooksRecursive(t *testing.T) {
	svc, _, _, _ := newImportFixture(t, map[string]string{
		"/legado-desktop/a.txt":          "text-a",
		"/legado-desktop/b.epub":         "epub-b",
		"/legado-desktop/cover.jpg":      "not-a-book",
		"/legado-desktop/sub/c.pdf":      "pdf-c",
		"/legado-desktop/sub/deep/d.cbz": "comic-d",
		"/legado-desktop/.hidden/e.txt":  "hidden",
		"/legado-desktop/backups/x.db":   "db",
	})
	books, err := svc.ScanBooks(context.Background(), "")
	if err != nil {
		t.Fatalf("ScanBooks 失败: %v", err)
	}
	got := make([]string, 0, len(books))
	for _, b := range books {
		got = append(got, b.Path)
	}
	want := []string{"a.txt", "b.epub", "sub/c.pdf", "sub/deep/d.cbz"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("扫描结果不符\n got: %v\nwant: %v", got, want)
	}
	for _, b := range books {
		if b.Format == "" {
			t.Fatalf("%s 缺少格式标注", b.Path)
		}
	}
}

// 导入要把文件落到 <root>/webdav/ 并保持远端层级，再交给导入器。
func TestWebDAVImportDownloadsToDataDir(t *testing.T) {
	svc, _, imp, root := newImportFixture(t, map[string]string{
		"/legado-desktop/books/a.txt":     "hello-a",
		"/legado-desktop/books/sub/b.txt": "hello-b",
	})

	if _, err := svc.StartBookImport(context.Background(), []string{"books"}, 0); err != nil {
		t.Fatalf("StartBookImport 失败: %v", err)
	}
	job := waitIdle(t, svc)
	if job.State != dto.WebDAVImportDone {
		t.Fatalf("期望 done，实际 %s（%s）", job.State, job.Message)
	}
	if job.Done != 2 || job.Failed != 0 {
		t.Fatalf("期望成功 2 失败 0，实际 %d/%d", job.Done, job.Failed)
	}

	for _, rel := range []string{"books/a.txt", "books/sub/b.txt"} {
		p := filepath.Join(root, "webdav", filepath.FromSlash(rel))
		data, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("本地文件 %s 不存在: %v", p, err)
		}
		if !strings.HasPrefix(string(data), "hello") {
			t.Fatalf("%s 内容不对: %q", p, string(data))
		}
	}

	imported := imp.imported()
	if len(imported) != 2 {
		t.Fatalf("应导入 2 本，实际 %d: %v", len(imported), imported)
	}
	for _, p := range imported {
		// 必须落在数据目录内：书架存的是绝对路径，放临时目录重启后就失效了。
		if !strings.HasPrefix(p, filepath.Join(root, "webdav")) {
			t.Fatalf("导入路径不在数据目录内: %s", p)
		}
	}
	// 半成品文件不能留下。
	if _, err := os.Stat(filepath.Join(root, "webdav", "books", "a.txt.part")); err == nil {
		t.Fatal("不应残留 .part 文件")
	}
}

// 单文件导入也要工作（前端可以只勾一个文件）。
func TestWebDAVImportSingleFile(t *testing.T) {
	svc, _, imp, _ := newImportFixture(t, map[string]string{
		"/legado-desktop/books/a.txt": "x",
	})
	if _, err := svc.StartBookImport(context.Background(), []string{"books/a.txt"}, 0); err != nil {
		t.Fatalf("StartBookImport 失败: %v", err)
	}
	job := waitIdle(t, svc)
	if job.State != dto.WebDAVImportDone || job.Done != 1 {
		t.Fatalf("期望 1 本成功，实际 %s done=%d（%s）", job.State, job.Done, job.Message)
	}
	if len(imp.imported()) != 1 {
		t.Fatalf("应导入 1 本，实际 %v", imp.imported())
	}
}

// 目录里没有书时要给出可读提示，而不是静默成功。
func TestWebDAVImportNoBooks(t *testing.T) {
	svc, _, _, _ := newImportFixture(t, map[string]string{
		"/legado-desktop/notes/readme.md": "not a book",
	})
	if _, err := svc.StartBookImport(context.Background(), []string{"notes"}, 0); err != nil {
		t.Fatalf("StartBookImport 失败: %v", err)
	}
	job := waitIdle(t, svc)
	if job.State != dto.WebDAVImportFailed {
		t.Fatalf("期望 failed，实际 %s", job.State)
	}
	if !strings.Contains(job.Message, "没有可导入的书籍") {
		t.Fatalf("提示应说明没找到书，实际 %q", job.Message)
	}
}

// 单个文件解析失败不影响其它文件（沿用导入的「部分成功」语义）。
func TestWebDAVImportPartialFailure(t *testing.T) {
	svc, _, imp, _ := newImportFixture(t, map[string]string{
		"/legado-desktop/books/ok.txt":  "good",
		"/legado-desktop/books/bad.txt": "broken",
	})
	imp.fail["bad.txt"] = true

	if _, err := svc.StartBookImport(context.Background(), []string{"books"}, 0); err != nil {
		t.Fatalf("StartBookImport 失败: %v", err)
	}
	job := waitIdle(t, svc)
	if job.State != dto.WebDAVImportDone {
		t.Fatalf("部分失败仍应算完成，实际 %s", job.State)
	}
	if job.Done != 1 || job.Failed != 1 {
		t.Fatalf("期望 1 成功 1 失败，实际 %d/%d", job.Done, job.Failed)
	}
	if len(job.Failures) != 1 || !strings.Contains(job.Failures[0].Path, "bad.txt") {
		t.Fatalf("失败明细不对: %+v", job.Failures)
	}
}

// 同一时刻只允许一个导入任务。
func TestWebDAVImportIsSerial(t *testing.T) {
	svc, dav, _, _ := newImportFixture(t, map[string]string{
		"/legado-desktop/books/a.txt": strings.Repeat("x", 4096),
	})
	dav.chunkDelay = 20 * time.Millisecond

	if _, err := svc.StartBookImport(context.Background(), []string{"books"}, 0); err != nil {
		t.Fatalf("第一次启动失败: %v", err)
	}
	if _, err := svc.StartBookImport(context.Background(), []string{"books"}, 0); err == nil {
		t.Fatal("第二个任务应被拒绝")
	} else if !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("错误类型不对: %v", err)
	}
	_ = svc.CancelBookImport()
}

// 取消后状态为 canceled，且不残留 .part。
func TestWebDAVImportCancel(t *testing.T) {
	svc, dav, _, root := newImportFixture(t, map[string]string{
		"/legado-desktop/books/big.txt": strings.Repeat("y", 200000),
	})
	dav.chunkDelay = 5 * time.Millisecond

	if _, err := svc.StartBookImport(context.Background(), []string{"books"}, 0); err != nil {
		t.Fatalf("StartBookImport 失败: %v", err)
	}
	time.Sleep(40 * time.Millisecond)
	if err := svc.CancelBookImport(); err != nil {
		t.Fatalf("取消失败: %v", err)
	}
	job := svc.ImportStatus()
	if job.State != dto.WebDAVImportCanceled {
		t.Fatalf("期望 canceled，实际 %s（%s）", job.State, job.Message)
	}
	matches, _ := filepath.Glob(filepath.Join(root, "webdav", "books", "*.part"))
	if len(matches) != 0 {
		t.Fatalf("取消后不应残留半成品: %v", matches)
	}
}

// 远端路径里的 .. 必须被拒绝，否则可以写到数据目录之外。
func TestWebDAVImportRejectsTraversal(t *testing.T) {
	svc, _, _, _ := newImportFixture(t, map[string]string{})
	for _, p := range []string{"../etc/passwd", "books/../../x.txt", "  "} {
		if _, err := svc.StartBookImport(context.Background(), []string{p}, 0); err == nil {
			t.Fatalf("%q 应被拒绝", p)
		}
	}
}

// 未注入导入能力时给出明确错误，而不是空指针。
func TestWebDAVImportWithoutCapability(t *testing.T) {
	svc := NewWebDAVService(memSettings{raw: `{"url":"http://dav.local"}`}, memDAVFactory{client: newMemDAV(nil)}, nil, "")
	if _, err := svc.StartBookImport(context.Background(), []string{"a.txt"}, 0); !errors.Is(err, domain.ErrNotConfigured) {
		t.Fatalf("期望 ErrNotConfigured，实际 %v", err)
	}
}

// safeRelPath 的边界。
func TestSafeRelPath(t *testing.T) {
	cases := []struct {
		in   string
		want string
		bad  bool
	}{
		{"a.txt", "a.txt", false},
		{"/books/a.txt", "books/a.txt", false},
		{"books//a.txt", "books/a.txt", false},
		{`books\a.txt`, "books/a.txt", false},
		{"books/./a.txt", "books/a.txt", false},
		{"", "", true},
		{"   ", "", true},
		{"../a.txt", "", true},
		{"a/../../b", "", true},
	}
	for _, c := range cases {
		got, err := safeRelPath(c.in)
		if c.bad {
			if err == nil {
				t.Fatalf("%q 应报错，实际得到 %q", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Fatalf("%q 不应报错: %v", c.in, err)
		}
		if got != c.want {
			t.Fatalf("%q → %q，期望 %q", c.in, got, c.want)
		}
	}
}

// List 必须返回相对工作根的路径：前端会把它原样回传给 List / 下载 / 删除，
// 而这三处都会自己再拼一次 remoteRoot。返回完整路径会导致 /legado-desktop/legado-desktop/... 404。
func TestWebDAVListReturnsRelativePaths(t *testing.T) {
	svc, _, _, _ := newImportFixture(t, map[string]string{
		"/legado-desktop/novels/a.txt":    "x",
		"/legado-desktop/backups/db-1.db": "y",
	})
	entries, err := svc.List(context.Background(), "")
	if err != nil {
		t.Fatalf("List 失败: %v", err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Path, "/") || strings.Contains(e.Path, "legado-desktop") {
			t.Fatalf("路径应为相对工作根目录，实际 %q", e.Path)
		}
	}

	sub, err := svc.List(context.Background(), "novels")
	if err != nil {
		t.Fatalf("List 子目录失败: %v", err)
	}
	if len(sub) != 1 || sub[0].Path != "novels/a.txt" {
		t.Fatalf("子目录路径不对: %+v", sub)
	}
}
