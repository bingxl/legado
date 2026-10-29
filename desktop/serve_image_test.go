package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestRefererFor(t *testing.T) {
	cases := []struct{ in, want string }{
		{"https://manwame.com", "https://manwame.com/"},
		{"https://manwame.com/book/x-L1D63", "https://manwame.com/"},
		{"http://example.com:8080/a/b", "http://example.com:8080/"},
		{"", ""},
		{"manwame.com", ""},
		{"file:///c:/x", ""},
	}
	for _, c := range cases {
		if got := refererFor(c.in); got != c.want {
			t.Errorf("refererFor(%q) = %q，期望 %q", c.in, got, c.want)
		}
	}
}

// 代理要带上书源域名的 Referer，否则图床会 403（这正是引入代理的原因）。
func TestServeRemoteImageForwardsReferer(t *testing.T) {
	var gotReferer, gotUA string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotReferer = r.Header.Get("Referer")
		gotUA = r.Header.Get("User-Agent")
		w.Header().Set("Content-Type", "image/webp")
		_, _ = w.Write([]byte("FAKEIMAGE"))
	}))
	defer upstream.Close()

	q := url.Values{}
	q.Set("u", upstream.URL+"/a/1.webp")
	q.Set("src", "https://manwame.com")
	rec := httptest.NewRecorder()
	serveRemoteImage(rec, httptest.NewRequest(http.MethodGet, "/img/?"+q.Encode(), nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 %d，期望 200", rec.Code)
	}
	if body := rec.Body.String(); body != "FAKEIMAGE" {
		t.Fatalf("响应体 %q 不是上游内容", body)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "image/webp" {
		t.Fatalf("Content-Type = %q", ct)
	}
	if gotReferer != "https://manwame.com/" {
		t.Fatalf("Referer = %q，期望 https://manwame.com/", gotReferer)
	}
	if gotUA == "" {
		t.Fatal("未透传 User-Agent")
	}
	if rec.Header().Get("Cache-Control") == "" {
		t.Fatal("缺少缓存头")
	}
}

// 只允许 http/https，避免被构造成读本地文件。
func TestServeRemoteImageRejectsOtherScheme(t *testing.T) {
	for _, raw := range []string{"file:///c:/windows/win.ini", "ftp://x/y", ""} {
		q := url.Values{}
		q.Set("u", raw)
		rec := httptest.NewRecorder()
		serveRemoteImage(rec, httptest.NewRequest(http.MethodGet, "/img/?"+q.Encode(), nil))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%q 应返回 400，实际 %d", raw, rec.Code)
		}
	}
}

// 上游失败时不要把错误页当成图片返回。
func TestServeRemoteImageUpstreamError(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "forbidden", http.StatusForbidden)
	}))
	defer upstream.Close()

	q := url.Values{}
	q.Set("u", upstream.URL+"/x.jpg")
	rec := httptest.NewRecorder()
	serveRemoteImage(rec, httptest.NewRequest(http.MethodGet, "/img/?"+q.Encode(), nil))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("状态码 %d，期望透传 403", rec.Code)
	}
}
