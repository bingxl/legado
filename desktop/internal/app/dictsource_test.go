package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/legado/desktop/internal/app/dictdata"
	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// dictMemSettings 是内存版配置存储。
type dictMemSettings struct{ m map[string]string }

func newMemSettings() *dictMemSettings { return &dictMemSettings{m: map[string]string{}} }

func (s *dictMemSettings) Get(_ context.Context, key string) (string, error) {
	if v, ok := s.m[key]; ok {
		return v, nil
	}
	return "", domain.ErrNotFound
}

func (s *dictMemSettings) Set(_ context.Context, key, value string) error {
	s.m[key] = value
	return nil
}

func (s *dictMemSettings) Delete(_ context.Context, key string) error {
	delete(s.m, key)
	return nil
}

func TestParseCustom(t *testing.T) {
	cases := []struct {
		in      string
		want    string
		wantVal string
		errPart string
	}{
		{in: "https://my.proxy/?u={url}", want: customTemplate},
		{in: "https://ghfast.top", want: customPrefix, wantVal: "https://ghfast.top/"},
		{in: "https://ghfast.top/", want: customPrefix, wantVal: "https://ghfast.top/"},
		{in: "https://nas.local/packs/en-zh.full.db", want: customDirect},
		{in: "http://192.168.1.9:8080/dict/cedict_ts.u8", want: customDirect},
		{in: "file:///C:/Windows/win.ini", errPart: "只支持"},
		{in: "javascript:alert(1)", errPart: "只支持"},
		{in: "ghfast.top", errPart: "http"},
		{in: "  ", errPart: "请填写"},
	}
	for _, c := range cases {
		kind, val, err := parseCustom(c.in)
		if c.errPart != "" {
			if err == nil || !strings.Contains(err.Error(), c.errPart) {
				t.Errorf("parseCustom(%q) 期望错误含 %q，得到 kind=%q err=%v", c.in, c.errPart, kind, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseCustom(%q) 意外失败: %v", c.in, err)
			continue
		}
		if kind != c.want {
			t.Errorf("parseCustom(%q) 形态 = %q，期望 %q", c.in, kind, c.want)
		}
		if c.wantVal != "" && val != c.wantVal {
			t.Errorf("parseCustom(%q) 值 = %q，期望 %q", c.in, val, c.wantVal)
		}
	}
}

func TestAssembleURL(t *testing.T) {
	coord := dictdata.SourceCoord{
		Repo: "skywind3000/ECDICT",
		Ref:  "abc123",
		Path: "ecdict.csv",
		Form: "raw",
	}
	release := coord
	release.Form = "release"

	cases := []struct {
		name   string
		src    dictSource
		coord  dictdata.SourceCoord
		custom string
		want   string
	}{
		{
			name:  "github 直连 raw",
			src:   dictSource{Kind: "direct"},
			coord: coord,
			want:  "https://raw.githubusercontent.com/skywind3000/ECDICT/abc123/ecdict.csv",
		},
		{
			name:  "github 直连 release",
			src:   dictSource{Kind: "direct"},
			coord: release,
			want:  "https://github.com/skywind3000/ECDICT/releases/download/abc123/ecdict.csv",
		},
		{
			name:  "前缀镜像",
			src:   dictSource{Kind: "prefix", Prefix: "https://ghfast.top/"},
			coord: coord,
			want:  "https://ghfast.top/https://raw.githubusercontent.com/skywind3000/ECDICT/abc123/ecdict.csv",
		},
		{
			name:  "jsdelivr 改写",
			src:   dictSource{Kind: "jsdelivr"},
			coord: coord,
			want:  "https://cdn.jsdelivr.net/gh/skywind3000/ECDICT@abc123/ecdict.csv",
		},
		{
			name:   "自定义前缀",
			src:    dictSource{Kind: "custom"},
			coord:  coord,
			custom: "https://mirror.local/gh",
			want:   "https://mirror.local/gh/https://raw.githubusercontent.com/skywind3000/ECDICT/abc123/ecdict.csv",
		},
		{
			name:   "自定义模板",
			src:    dictSource{Kind: "custom"},
			coord:  coord,
			custom: "https://proxy.local/?u={url}",
			want:   "https://proxy.local/?u=https://raw.githubusercontent.com/skywind3000/ECDICT/abc123/ecdict.csv",
		},
		{
			name:   "自定义完整文件",
			src:    dictSource{Kind: "custom"},
			coord:  coord,
			custom: "https://nas.local/packs/ecdict.csv",
			want:   "https://nas.local/packs/ecdict.csv",
		},
	}
	for _, c := range cases {
		got, err := assembleURL(c.src, c.coord, c.custom)
		if err != nil {
			t.Errorf("%s: 意外失败 %v", c.name, err)
			continue
		}
		if got != c.want {
			t.Errorf("%s:\n 得到 %s\n 期望 %s", c.name, got, c.want)
		}
	}
}

// TestSourcesForCapacity 守住「不让人下到 100% 才失败」这条：
// jsDelivr 有 20 MB 硬上限，全量包必须置灰并给出带数字的原因。
func TestSourcesForCapacity(t *testing.T) {
	svc := NewDictService(DictDeps{Root: t.TempDir(), Settings: newMemSettings()})

	full, err := svc.SourcesFor(ctxOf(), "en-zh-full")
	if err != nil {
		t.Fatal(err)
	}
	var js *dto.DictSourceView
	for i := range full {
		if full[i].ID == DictSourceIDJsdelivr {
			js = &full[i]
		}
	}
	if js == nil {
		t.Fatal("源列表里没有 jsDelivr")
	}
	if js.Usable {
		t.Error("jsDelivr 对 63 MB 的全量包应判为不可用")
	}
	if !strings.Contains(js.Reason, "20") || !strings.Contains(js.Reason, "MB") {
		t.Errorf("不可用原因要带上具体数字，得到 %q", js.Reason)
	}

	zh, err := svc.SourcesFor(ctxOf(), "zh-en")
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range zh {
		if s.ID == DictSourceIDJsdelivr && !s.Usable {
			t.Errorf("汉英包 8.6 MB 应能走 jsDelivr，却被判为不可用：%s", s.Reason)
		}
	}
}

func TestInstallOrderSkipsOversized(t *testing.T) {
	svc := NewDictService(DictDeps{Root: t.TempDir(), Settings: newMemSettings()})
	pack, ok := dictdata.ExtPack("en-zh-full")
	if !ok {
		t.Fatal("清单里没有 en-zh-full")
	}
	order := svc.installOrder(defaultSourceSettings(), pack, "", "")
	if len(order) == 0 {
		t.Fatal("自动模式不应没有可用源")
	}
	for _, src := range order {
		if src.ID == DictSourceIDJsdelivr {
			t.Error("自动换源顺序里不该出现必然失败的 jsDelivr（20 MB 上限）")
		}
	}
	// 手动指定时也要过滤：否则用户选中就是必然 403。
	manual := svc.installOrder(defaultSourceSettings(), pack, DictSourceIDJsdelivr, "")
	if len(manual) != 0 {
		t.Errorf("手动选中超限的源应返回空列表，得到 %d 项", len(manual))
	}
}

func TestSetSourceValidation(t *testing.T) {
	svc := NewDictService(DictDeps{Root: t.TempDir(), Settings: newMemSettings()})
	if err := svc.SetSource(ctxOf(), "auto", DictSourceIDGhfast, ""); err != nil {
		t.Fatalf("合法配置被拒: %v", err)
	}
	if err := svc.SetSource(ctxOf(), "auto", "not-exist", ""); err == nil {
		t.Error("未知源应被拒绝")
	}
	if err := svc.SetSource(ctxOf(), "auto", DictSourceIDCustom, "file:///etc/passwd"); err == nil {
		t.Error("file:// 应被拒绝")
	}
	if err := svc.SetSource(ctxOf(), "auto", DictSourceIDCustom, ""); err == nil {
		t.Error("选中自定义却留空应被拒绝")
	}
	// 存下来的配置要能读回，且自定义串的形态能被识别。
	if err := svc.SetSource(ctxOf(), "manual", DictSourceIDCustom, "https://ghfast.top"); err != nil {
		t.Fatalf("保存自定义源失败: %v", err)
	}
	cfg := svc.loadSourceSettings(ctxOf())
	if cfg.Mode != "manual" || cfg.SourceID != DictSourceIDCustom {
		t.Errorf("配置未落盘: %+v", cfg)
	}
}

// ── 下载与校验 ─────────────────────────────────────────────────

func packFor(data []byte) dictdata.Pack {
	sum := sha256.Sum256(data)
	return dictdata.Pack{
		ID:       "en-zh-full",
		Name:     "测试包",
		FileName: "en-zh.full.db",
		Kind:     "ecdict",
		Tier:     "full",
		Source: dictdata.SourceCoord{
			Repo:   "x/y",
			Ref:    "v1",
			Path:   "a.csv",
			Form:   "raw",
			Size:   int64(len(data)),
			SHA256: hex.EncodeToString(sum[:]),
		},
	}
}

// rangeServer 模拟一个支持 Range 的镜像，并记录收到的 Range 头。
func rangeServer(t *testing.T, data []byte, gotRange *string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if gotRange != nil {
			*gotRange = r.Header.Get("Range")
		}
		start := 0
		if rng := r.Header.Get("Range"); strings.HasPrefix(rng, "bytes=") {
			fmt.Sscanf(strings.TrimSuffix(strings.TrimPrefix(rng, "bytes="), "-"), "%d", &start)
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, len(data)-1, len(data)))
			w.WriteHeader(http.StatusPartialContent)
		}
		_, _ = w.Write(data[start:])
	}))
}

func TestDownloadResume(t *testing.T) {
	data := make([]byte, 200<<10)
	for i := range data {
		data[i] = byte(i % 251)
	}
	var seenRange string
	srv := rangeServer(t, data, &seenRange)
	defer srv.Close()

	root := t.TempDir()
	svc := NewDictService(DictDeps{Root: root, Settings: newMemSettings()})
	pack := packFor(data)
	part := svc.partPath(pack.ID)
	if err := os.MkdirAll(filepath.Dir(part), 0o755); err != nil {
		t.Fatal(err)
	}
	// 先写半截，模拟上次中断。
	if err := os.WriteFile(part, data[:50<<10], 0o644); err != nil {
		t.Fatal(err)
	}

	src := resolvedSource{dictSource: dictSource{ID: "test", Name: "测试源", Kind: "direct"}}
	if err := svc.download(ctxOf(), pack, src, srv.URL, part, ""); err != nil {
		t.Fatalf("续传失败: %v", err)
	}
	if seenRange == "" || !strings.HasPrefix(seenRange, "bytes=") {
		t.Errorf("续传应带 Range 头，实际 %q", seenRange)
	}
	if seenRange == "bytes=0-" {
		t.Errorf("应从中断处续传，实际 %q", seenRange)
	}
	got, err := os.ReadFile(part)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(data) {
		t.Fatalf("续传后体积 %d，期望 %d", len(got), len(data))
	}
	for i := range data {
		if got[i] != data[i] {
			t.Fatalf("第 %d 字节不符", i)
		}
	}
	if err := svc.verify(pack, part, ctxOf(), src); err != nil {
		t.Errorf("校验应通过: %v", err)
	}
}

// TestDownloadIgnoresServerRange 守住一个很容易写错的坑：
// 服务器无视 Range 回了 200 整包时，不能把整包追加到已有前缀后面。
func TestDownloadIgnoresServerRange(t *testing.T) {
	data := []byte(strings.Repeat("abcdefgh", 4096)) // 32 KB
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		// 永远回整包，且不带 206。
		_, _ = w.Write(data)
	}))
	defer srv.Close()

	svc := NewDictService(DictDeps{Root: t.TempDir(), Settings: newMemSettings()})
	pack := packFor(data)
	part := svc.partPath(pack.ID)
	if err := os.MkdirAll(filepath.Dir(part), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(part, data[:4096], 0o644); err != nil {
		t.Fatal(err)
	}
	src := resolvedSource{dictSource: dictSource{ID: "test", Name: "测试源", Kind: "direct"}}
	if err := svc.download(ctxOf(), pack, src, srv.URL, part, ""); err != nil {
		t.Fatalf("下载失败: %v", err)
	}
	got, _ := os.ReadFile(part)
	if len(got) != len(data) {
		t.Fatalf("体积 %d，期望 %d（服务器无视 Range 时应从头重写）", len(got), len(data))
	}
}

func TestVerifyRejectsHashMismatch(t *testing.T) {
	data := []byte("not the right bytes")
	srv := rangeServer(t, data, nil)
	defer srv.Close()

	svc := NewDictService(DictDeps{Root: t.TempDir(), Settings: newMemSettings()})
	pack := packFor([]byte("expected content"))
	part := svc.partPath(pack.ID)
	if err := os.MkdirAll(filepath.Dir(part), 0o755); err != nil {
		t.Fatal(err)
	}
	// 体积对齐、哈希不符：走的是哈希分支而不是体积分支。
	bad := []byte(strings.Repeat("x", len(pack.Source.SHA256)))
	if err := os.WriteFile(part, bad, 0o644); err != nil {
		t.Fatal(err)
	}
	pack.Source.Size = int64(len(bad))
	err := svc.verify(pack, part, ctxOf(), resolvedSource{})
	if err == nil {
		t.Fatal("哈希不符应报错")
	}
	if _, ok := err.(*verifyError); !ok {
		t.Errorf("哈希不符应标记为 verifyError（不可续传），得到 %T", err)
	}
}

// TestConvertAndCommit 覆盖「转换 → 校验 → 原子落位」这条链路。
func TestConvertAndCommit(t *testing.T) {
	root := t.TempDir()
	svc := NewDictService(DictDeps{
		Root:     root,
		Settings: newMemSettings(),
		Events:   &fakeEventBus{},
		OpenRepo: func(string) (port.DictionaryRepository, error) {
			return &fakeDict{}, nil
		},
		Build: func(_ context.Context, _, _, outPath, _ string, progress func(done, total int64)) (int, error) {
			if err := os.WriteFile(outPath, []byte("fake db"), 0o644); err != nil {
				return 0, err
			}
			progress(50, 100)
			progress(100, 100)
			return 38243, nil
		},
	})
	pack, ok := dictdata.ExtPack("zh-en")
	if !ok {
		t.Fatal("清单里没有 zh-en")
	}
	src := filepath.Join(root, "cedict_ts.u8")
	if err := os.WriteFile(src, []byte("# fake\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	svc.convertAndCommit(ctxOf(), pack, src, 0, "test", "测试源")

	final := filepath.Join(root, "dict", pack.FileName)
	if _, err := os.Stat(final); err != nil {
		t.Fatalf("安装后应有 %s: %v", final, err)
	}
	if _, err := os.Stat(final + ".tmp"); err == nil {
		t.Error("临时文件应已 rename，不该残留")
	}

	bus := svc.events.(*fakeEventBus)
	payloads := bus.byName(port.EventDictInstallProgress)
	if len(payloads) == 0 {
		t.Fatal("应推送安装进度事件")
	}
	last := payloads[len(payloads)-1].(dto.DictInstallProgress)
	if last.Phase != dto.DictPhaseDone {
		t.Errorf("最后一条事件应为 done，得到 %q（%s）", last.Phase, last.Message)
	}
	if last.Entries != 38243 {
		t.Errorf("词条数 = %d，期望 38243", last.Entries)
	}
	// 序号必须递增，否则前端丢过期事件的机制失效。
	var prev int64
	for _, p := range payloads {
		seq := p.(dto.DictInstallProgress).Seq
		if seq <= prev {
			t.Errorf("事件序号未递增：%d 紧跟在 %d 之后", seq, prev)
		}
		prev = seq
	}
}

func TestRemoveRefusesBuiltin(t *testing.T) {
	svc := NewDictService(DictDeps{Root: t.TempDir(), Settings: newMemSettings()})
	if err := svc.Remove(ctxOf(), "en-zh-core"); err == nil {
		t.Error("内置核心词库不能删除")
	}
}

// strictDict 只在「查 zh 表」时成功，查 word 表一律报错。
//
// 用来守住一个真实踩过的坑：汉英库只有 zh 表，若体检时仍拿英文库的
// PrefixWords 去探，汉英包会永远装不上，而且只闪一条界面提示。
type strictDict struct{ fakeDict }

func (s *strictDict) PrefixWords(context.Context, string, int) ([]string, error) {
	return nil, errors.New("no such table: word")
}

func (s *strictDict) LookupZh(context.Context, string) ([]domain.DictEntry, error) {
	return []domain.DictEntry{{Word: "苹果", Translation: "apple"}}, nil
}

func TestConvertAndCommitCedictChecksZhTable(t *testing.T) {
	root := t.TempDir()
	svc := NewDictService(DictDeps{
		Root:     root,
		Settings: newMemSettings(),
		Events:   &fakeEventBus{},
		OpenRepo: func(string) (port.DictionaryRepository, error) {
			return &strictDict{}, nil
		},
		Build: func(_ context.Context, _, _, outPath, _ string, _ func(done, total int64)) (int, error) {
			return 125394, os.WriteFile(outPath, []byte("fake db"), 0o644)
		},
	})
	pack, ok := dictdata.ExtPack("zh-en")
	if !ok {
		t.Fatal("清单里没有 zh-en")
	}
	src := filepath.Join(root, "cedict_ts.u8")
	if err := os.WriteFile(src, []byte("# fake\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	svc.convertAndCommit(ctxOf(), pack, src, 0, "test", "测试源")

	if _, err := os.Stat(filepath.Join(root, "dict", pack.FileName)); err != nil {
		t.Fatalf("汉英库应已落位（体检不能拿 word 表去探）: %v", err)
	}
}
