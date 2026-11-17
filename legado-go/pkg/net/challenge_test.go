package net

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/store"
)

func TestIsCloudflareChallenge(t *testing.T) {
	cases := []struct {
		name    string
		status  int
		headers map[string]string
		body    string
		want    bool
	}{
		{
			name:    "cf-mitigated 头是权威信号",
			status:  http.StatusForbidden,
			headers: map[string]string{"Cf-Mitigated": "challenge"},
			body:    "<html></html>",
			want:    true,
		},
		{
			name:    "cf-mitigated 大小写不敏感",
			status:  http.StatusForbidden,
			headers: map[string]string{"cf-mitigated": "Challenge"},
			body:    "",
			want:    true,
		},
		{
			name:    "403 + _cf_chl_opt 特征",
			status:  http.StatusForbidden,
			headers: nil,
			body:    `<script>window._cf_chl_opt={cvId:'3'}</script>`,
			want:    true,
		},
		{
			name:    "503 + Just a moment",
			status:  http.StatusServiceUnavailable,
			headers: nil,
			body:    `<title>Just a moment...</title>`,
			want:    true,
		},
		{
			name:    "中文挑战页",
			status:  http.StatusForbidden,
			headers: nil,
			body:    `<div>正在验证您是否是真人。请稍候...</div>`,
			want:    true,
		},
		{
			name:    "2xx 正文含关键字不算拦截",
			status:  http.StatusOK,
			headers: map[string]string{"Server": "cloudflare"},
			body:    `书评：Just a moment... 这句话很好`,
			want:    false,
		},
		{
			name:    "普通 403 不是挑战页",
			status:  http.StatusForbidden,
			headers: map[string]string{"Server": "cloudflare"},
			body:    `<h1>Forbidden</h1>`,
			want:    false,
		},
		{
			name:    "只有 Server: cloudflare 不能判定",
			status:  http.StatusOK,
			headers: map[string]string{"Server": "cloudflare", "Cf-Ray": "abc"},
			body:    `<html>正常页面</html>`,
			want:    false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, reason := IsCloudflareChallenge(c.status, c.headers, c.body)
			if got != c.want {
				t.Fatalf("IsCloudflareChallenge = %v（%s），期望 %v", got, reason, c.want)
			}
			if got && reason == "" {
				t.Fatal("命中时应给出判定依据")
			}
		})
	}
}

// challengeServer 造一个"首次返回挑战页、带 cf_clearance 后放行"的上游。
type challengeServer struct {
	*httptest.Server
	hits     int
	cookie   string
	ua       string
	bodySeen string
}

func newChallengeServer(t *testing.T, okBody string) *challengeServer {
	t.Helper()
	cs := &challengeServer{}
	cs.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cs.hits++
		if !strings.Contains(r.Header.Get("Cookie"), "cf_clearance=") {
			w.Header().Set("cf-mitigated", "challenge")
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, `<html><script>window._cf_chl_opt={}</script></html>`)
			return
		}
		cs.cookie = r.Header.Get("Cookie")
		cs.ua = r.Header.Get("User-Agent")
		cs.bodySeen = r.Method
		_, _ = io.WriteString(w, okBody)
	}))
	t.Cleanup(cs.Close)
	return cs
}

// resetChallenge 清理包级状态，避免用例之间互相串味。
func resetChallenge(t *testing.T) {
	t.Helper()
	old := ChallengeHandler
	ResetChallengeState()
	store.Default().RemoveCookie("http://127.0.0.1/")
	t.Cleanup(func() {
		ChallengeHandler = old
		ResetChallengeState()
		store.Default().RemoveCookie("http://127.0.0.1/")
	})
}

func TestDoSolvesChallengeAndRetries(t *testing.T) {
	resetChallenge(t)
	srv := newChallengeServer(t, "SUCCESS-BODY")

	var gotChallenge Challenge
	ChallengeHandler = func(c Challenge) (ChallengeResult, error) {
		gotChallenge = c
		return ChallengeResult{Cookie: "cf_clearance=ok", UserAgent: "BrowserUA/1.0"}, nil
	}

	resp, err := Default().Do(Options{URL: srv.URL + "/book/1", SaveCookie: true})
	if err != nil {
		t.Fatalf("请求出错: %v", err)
	}
	if resp.Body != "SUCCESS-BODY" {
		t.Fatalf("验证通过后应拿到正文，实际 %q（状态 %d）", resp.Body, resp.StatusCode)
	}
	if srv.hits != 2 {
		t.Fatalf("应恰好请求两次（挑战 + 带凭证重试），实际 %d", srv.hits)
	}
	if !strings.Contains(srv.cookie, "cf_clearance=ok") {
		t.Fatalf("重试未带上验证拿到的 Cookie：%q", srv.cookie)
	}
	// cf_clearance 与 UA 绑定：必须换成浏览器的 UA，否则上游仍然拒绝
	if srv.ua != "BrowserUA/1.0" {
		t.Fatalf("重试未使用浏览器 UA，实际 %q", srv.ua)
	}
	if gotChallenge.StatusCode != http.StatusForbidden || gotChallenge.Reason == "" {
		t.Fatalf("交给宿主的信息不完整：%+v", gotChallenge)
	}
}

func TestDoKeepsSourceUAWhenNoOverride(t *testing.T) {
	resetChallenge(t)
	var ua string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ua = r.Header.Get("User-Agent")
		_, _ = io.WriteString(w, "ok")
	}))
	defer srv.Close()

	if _, err := Default().Do(Options{
		URL:     srv.URL,
		Headers: map[string]string{"user-agent": "SourceUA/2.0"},
	}); err != nil {
		t.Fatalf("请求出错: %v", err)
	}
	if ua != "SourceUA/2.0" {
		t.Fatalf("没有验证覆盖时应尊重书源 UA，实际 %q", ua)
	}
}

func TestDoStopsWhenChallengeDeclined(t *testing.T) {
	resetChallenge(t)
	srv := newChallengeServer(t, "SHOULD-NOT-REACH")
	ChallengeHandler = func(Challenge) (ChallengeResult, error) {
		return ChallengeResult{Skip: true}, nil
	}

	resp, err := Default().Do(Options{URL: srv.URL})
	if err != nil {
		t.Fatalf("请求出错: %v", err)
	}
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("用户放弃时应原样返回挑战页，实际状态 %d", resp.StatusCode)
	}
	if srv.hits != 1 {
		t.Fatalf("用户放弃后不应重试，实际请求 %d 次", srv.hits)
	}
}

// 验证窗口通过了但凭证仍无效（常见于 IP 变化 / 凭证过期）时，
// 不能无限弹窗——只试一次，之后原样返回。
func TestDoSolvesChallengeAtMostOnce(t *testing.T) {
	resetChallenge(t)
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("cf-mitigated", "challenge")
		w.WriteHeader(http.StatusForbidden)
		_, _ = io.WriteString(w, "blocked")
	}))
	defer srv.Close()
	ChallengeHandler = func(Challenge) (ChallengeResult, error) {
		calls++
		return ChallengeResult{Cookie: "cf_clearance=stale", UserAgent: "UA"}, nil
	}

	resp, err := Default().Do(Options{URL: srv.URL, Retry: 2})
	if err != nil {
		t.Fatalf("请求出错: %v", err)
	}
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("凭证无效时应返回被拦截的响应，实际 %d", resp.StatusCode)
	}
	if calls != 1 {
		t.Fatalf("人工验证最多触发一次，实际 %d 次", calls)
	}
}

// 宿主拿不到 Cookie、但把浏览器渲染结果给了回来：直接当响应体用。
func TestDoUsesBodyWhenNoCookie(t *testing.T) {
	resetChallenge(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("cf-mitigated", "challenge")
		w.WriteHeader(http.StatusForbidden)
		_, _ = io.WriteString(w, "challenge")
	}))
	defer srv.Close()
	ChallengeHandler = func(Challenge) (ChallengeResult, error) {
		return ChallengeResult{Body: "<html>渲染后的正文</html>"}, nil
	}

	resp, err := Default().Do(Options{URL: srv.URL})
	if err != nil {
		t.Fatalf("请求出错: %v", err)
	}
	if resp.StatusCode != http.StatusOK || resp.Body != "<html>渲染后的正文</html>" {
		t.Fatalf("宿主回填的页面内容应直接作为响应，实际 %d %q", resp.StatusCode, resp.Body)
	}
}

// 验证后的"重新取正文"必须能跳过验证，否则会再次弹窗。
func TestDoNoChallengeSkipsHandler(t *testing.T) {
	resetChallenge(t)
	called := false
	srv := newChallengeServer(t, "never")
	ChallengeHandler = func(Challenge) (ChallengeResult, error) {
		called = true
		return ChallengeResult{Cookie: "cf_clearance=x"}, nil
	}

	resp, err := Default().Do(Options{URL: srv.URL, NoChallenge: true})
	if err != nil {
		t.Fatalf("请求出错: %v", err)
	}
	if called {
		t.Fatal("NoChallenge 时不应触发宿主验证")
	}
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("应原样返回挑战页，实际 %d", resp.StatusCode)
	}
}
