package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

// 路径段编码是安卓端能读到参数的前提：绝对路径里有 "/"、"C:" 和中文，
// 编码后必须能原样还原，扩展名要单独保留（安卓按它定 Content-Type）。
func TestAssetArgRoundTrip(t *testing.T) {
	cases := []string{
		`C:\Users\bingx\下载\bookSources.json`,
		`/data/user/0/cn.bingxl.legado/cache/wails-picker/1/书源.json`,
		"/sdcard/books/三体.epub",
	}
	for _, want := range cases {
		path := rawPrefix + encodeAssetArg(want) + ".json"
		r := httptest.NewRequest(http.MethodGet, path, nil)
		got, ok := decodeAssetArg(r, rawPrefix, "p")
		if !ok || got != want {
			t.Fatalf("decodeAssetArg(%q) = %q, %v，期望 %q", path, got, ok, want)
		}
	}
}

// 没有扩展名时也要能还原（漫画图片地址常以 ?x=1 结尾、或干脆没有后缀）。
func TestAssetArgNoExt(t *testing.T) {
	want := "https://img.example.com/a/1.webp?token=x"
	r := httptest.NewRequest(http.MethodGet, imgPrefix+encodeAssetArg(want), nil)
	got, ok := decodeAssetArg(r, imgPrefix, "u")
	if !ok || got != want {
		t.Fatalf("got %q, %v", got, ok)
	}
}

// 桌面端早期写法（查询串）必须继续可用，否则旧书签/缓存链接全断。
func TestDecodeAssetArgQueryFallback(t *testing.T) {
	q := url.Values{}
	q.Set("p", "/tmp/a.json")
	r := httptest.NewRequest(http.MethodGet, rawPrefix+"?"+q.Encode(), nil)
	got, ok := decodeAssetArg(r, rawPrefix, "p")
	if !ok || got != "/tmp/a.json" {
		t.Fatalf("got %q, %v", got, ok)
	}
}

func TestSplitExt(t *testing.T) {
	cases := []struct{ in, base, ext string }{
		{"YWJj.pdf", "YWJj", ".pdf"},
		{"YWJj", "YWJj", ""},
		{"a.b/c", "a.b/c", ""},                         // 非法扩展名（含 "/"）
		{"YWJj.verylongname", "YWJj.verylongname", ""}, // 太长，不像扩展名
	}
	for _, c := range cases {
		base, ext := splitExt(c.in)
		if base != c.base || ext != c.ext {
			t.Errorf("splitExt(%q) = %q, %q，期望 %q, %q", c.in, base, ext, c.base, c.ext)
		}
	}
}

// /raw/ 走路径段时能真的把文件读出来（安卓端导入书源、PDF 阅读都依赖这条）。
func TestServeRawFilePathForm(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "书源.json")
	if err := os.WriteFile(file, []byte(`[{"name":"测试"}]`), 0o644); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	serveRawFile(rec, httptest.NewRequest(http.MethodGet, rawPrefix+encodeAssetArg(file)+".json", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 %d，期望 200", rec.Code)
	}
	if body := rec.Body.String(); body != `[{"name":"测试"}]` {
		t.Fatalf("响应体 %q 与文件内容不一致", body)
	}
}

func TestServeRawFileMissing(t *testing.T) {
	rec := httptest.NewRecorder()
	serveRawFile(rec, httptest.NewRequest(http.MethodGet, rawPrefix, nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("状态码 %d，期望 400", rec.Code)
	}
}

// 代理地址走路径段时，书源地址要从 "地址\n书源" 里拆出来做 Referer。
func TestServeRemoteImagePathForm(t *testing.T) {
	var gotReferer string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotReferer = r.Header.Get("Referer")
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte("IMG"))
	}))
	defer upstream.Close()

	payload := upstream.URL + "/a/1.jpg" + "\n" + "https://manwame.com"
	rec := httptest.NewRecorder()
	serveRemoteImage(rec, httptest.NewRequest(http.MethodGet, imgPrefix+encodeAssetArg(payload)+".jpg", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 %d，期望 200", rec.Code)
	}
	if gotReferer != "https://manwame.com/" {
		t.Fatalf("Referer = %q，期望 https://manwame.com/", gotReferer)
	}
}
