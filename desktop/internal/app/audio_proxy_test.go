package app

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// TestProxyAudioFallbackToDirect 复现“系统代理把 Go 客户端的媒体请求 403 掉、
// 原版阅读 App 却正常”的现场：proxyClient 打到代理一律 403，directClient 直连
// 才 200。proxyAudio 必须在代理失败后用直连回退，把音频流正确透传出来。
func TestProxyAudioFallbackToDirect(t *testing.T) {
	// 直连目标：返回一段假音频。
	direct := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "audio/mpeg")
		w.Header().Set("Content-Length", "11")
		w.Header().Set("Accept-Ranges", "bytes")
		w.WriteHeader(200)
		io.WriteString(w, "fake-mp3!!!")
	}))
	defer direct.Close()

	// 代理：模拟国内代理/VPN 工具对 Go 客户端的拦截，一律 403。
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "Not Allowed For music.126.net", http.StatusForbidden)
	}))
	defer proxy.Close()

	proxyURL, _ := url.Parse(proxy.URL)
	proxyClient := &http.Client{
		Transport: &http.Transport{
			Proxy:                 http.ProxyURL(proxyURL),
			ResponseHeaderTimeout: 30 * time.Second,
			DisableCompression:    true,
			MaxIdleConnsPerHost:   4,
		},
	}
	directClient := &http.Client{
		Transport: &http.Transport{
			Proxy:                 nil,
			ResponseHeaderTimeout: 30 * time.Second,
			DisableCompression:    true,
			MaxIdleConnsPerHost:   4,
		},
	}

	svc := &AudioService{
		client:       proxyClient,
		directClient: directClient,
		sessions:     make(map[string]*audioSession),
	}

	// 会话真实地址指向直连目标；proxyClient 会被代理改写到 403，directClient 直连才通。
	sess := &audioSession{
		URL:     direct.URL + "/song.mp3",
		Headers: map[string]string{"Referer": "http://music.163.com/"},
	}
	svc.sessions["sid1"] = sess

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/stream/sid1.mp3", nil)
	svc.proxyAudio(rec, req, sess)

	if rec.Code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d body=%q", rec.Code, rec.Body.String())
	}
	if got := rec.Body.String(); got != "fake-mp3!!!" {
		t.Fatalf("音频内容透传错误: %q", got)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "audio/mpeg") {
		t.Fatalf("Content-Type 未透传: %q", ct)
	}
}

// TestProxyAudioNoFallbackWhenProxyOK 确认代理正常时不会无谓地二次请求直连。
func TestProxyAudioNoFallbackWhenProxyOK(t *testing.T) {
	direct := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "audio/mpeg")
		w.WriteHeader(200)
		io.WriteString(w, "ok-direct")
	}))
	defer direct.Close()

	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 代理正常把请求转发到真实地址（这里直接返回音频，不发真实外网）。
		w.Header().Set("Content-Type", "audio/mpeg")
		w.WriteHeader(200)
		io.WriteString(w, "ok-via-proxy")
	}))
	defer proxy.Close()

	proxyURL, _ := url.Parse(proxy.URL)
	proxyClient := &http.Client{
		Transport: &http.Transport{
			Proxy:                 http.ProxyURL(proxyURL),
			ResponseHeaderTimeout: 30 * time.Second,
			DisableCompression:    true,
			MaxIdleConnsPerHost:   4,
		},
	}
	directClient := &http.Client{
		Transport: &http.Transport{
			Proxy:                 nil,
			ResponseHeaderTimeout: 30 * time.Second,
			DisableCompression:    true,
			MaxIdleConnsPerHost:   4,
		},
	}

	svc := &AudioService{
		client:       proxyClient,
		directClient: directClient,
		sessions:     make(map[string]*audioSession),
	}
	sess := &audioSession{URL: direct.URL + "/song.mp3", Headers: map[string]string{}}
	svc.sessions["sid2"] = sess

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/stream/sid2.mp3", nil)
	svc.proxyAudio(rec, req, sess)

	if rec.Code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d", rec.Code)
	}
	if got := rec.Body.String(); got != "ok-via-proxy" {
		t.Fatalf("代理正常时应直接用代理结果，实际 body=%q", got)
	}
}

// TestProxyAudioFallbackOnHTMLIntercept 覆盖另一类现场：代理/网关不报错，
// 而是 200 返回一张 HTML 拦截页。这种响应 <audio> 只会报网络错误，必须回退直连。
func TestProxyAudioFallbackOnHTMLIntercept(t *testing.T) {
	direct := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "audio/mpeg")
		w.WriteHeader(200)
		io.WriteString(w, "real-audio")
	}))
	defer direct.Close()

	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(200)
		io.WriteString(w, "<html><body>blocked</body></html>")
	}))
	defer proxy.Close()

	proxyURL, _ := url.Parse(proxy.URL)
	svc := &AudioService{
		client: &http.Client{Transport: &http.Transport{
			Proxy: http.ProxyURL(proxyURL), DisableCompression: true,
		}},
		directClient: &http.Client{Transport: &http.Transport{Proxy: nil, DisableCompression: true}},
		sessions:     make(map[string]*audioSession),
	}
	sess := &audioSession{URL: direct.URL + "/song.mp3", Headers: map[string]string{}}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/stream/sid3.mp3", nil)
	svc.proxyAudio(rec, req, sess)

	if rec.Code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d", rec.Code)
	}
	if got := rec.Body.String(); got != "real-audio" {
		t.Fatalf("HTML 拦截页未回退直连，实际 body=%q", got)
	}
}
