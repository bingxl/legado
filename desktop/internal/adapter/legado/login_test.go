package legado

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	legadomodel "github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/store"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ── 测试站点 ────────────────────────────────────────────────
//
// 登录站点必须真跑一遍 HTTP 才说明问题：登录脚本的成败全在「Set-Cookie
// 有没有被引擎记住」上，mock 掉客户端等于什么都没验证。
type loginSite struct {
	srv *httptest.Server
	// sawCookie 记录 /search 收到的 Cookie，用来判断请求是否真的带上了登录态。
	sawCookie string
	// form 记录 /login 收到的表单值。
	form map[string]string
}

func newLoginSite(t *testing.T) *loginSite {
	t.Helper()
	s := &loginSite{}
	mux := http.NewServeMux()
	mux.HandleFunc("/login", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		s.form = map[string]string{}
		for k := range r.PostForm {
			s.form[k] = r.PostForm.Get(k)
		}
		if r.PostForm.Get("user") != "reader" || r.PostForm.Get("pass") != "p@ss" {
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, `{"ok":false,"msg":"账号或密码错误"}`)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "sid", Value: "OK", Path: "/"})
		_, _ = io.WriteString(w, `{"ok":true}`)
	})
	mux.HandleFunc("/search", func(w http.ResponseWriter, r *http.Request) {
		s.sawCookie = r.Header.Get("Cookie")
		if c, err := r.Cookie("sid"); err == nil && c.Value == "OK" {
			_, _ = io.WriteString(w, `<div class="item"><a href="/book/1">登录后可读的书</a></div>`)
			return
		}
		_, _ = io.WriteString(w, `<title>请先登录</title><div class="login">请登录后继续</div>`)
	})
	s.srv = httptest.NewServer(mux)
	t.Cleanup(s.srv.Close)
	// 所有用例共用 127.0.0.1 这个 cookie 域，跑前跑后都清干净，避免相互影响。
	resetCookie(t)
	t.Cleanup(func() { resetCookie(t) })
	return s
}

func resetCookie(t *testing.T) {
	t.Helper()
	store.Default().RemoveCookie("http://127.0.0.1")
}

// sourceJSON 造一个带登录脚本的书源。loginURL 由调用方指定。
func sourceJSON(t *testing.T, baseURL, loginURL, checkJS string) *domain.BookSource {
	t.Helper()
	raw := map[string]any{
		"bookSourceUrl":  baseURL,
		"bookSourceName": "登录测试源",
		"bookSourceType": 0,
		"loginUrl":       loginURL,
		"searchUrl":      "/search?q={{key}}",
		"header":         `{"User-Agent":"TestUA/1.0"}`,
	}
	if checkJS != "" {
		raw["loginCheckJs"] = checkJS
	}
	b, err := json.Marshal(raw)
	if err != nil {
		t.Fatalf("序列化书源失败: %v", err)
	}
	return &domain.BookSource{
		ID:      1,
		Name:    "登录测试源",
		URL:     baseURL,
		Raw:     string(b),
		Enabled: true,
	}
}

// 登录方式判定：与 Kotlin 原版一样按 loginUrl 的形态区分。
func TestLoginKind(t *testing.T) {
	l := NewLoginer("UA")
	cases := []struct {
		name string
		url  string
		kind string
		want string // 期望的 payload 片段
	}{
		{"空", "", port.LoginKindNone, ""},
		{"@js 前缀", "@js: function login(){return 1}", port.LoginKindJS, "function login"},
		{"<js> 包裹", "<js>var a=1;<js>", port.LoginKindJS, "var a=1"},
		{"绝对地址", "https://demo.test/login", port.LoginKindPage, "https://demo.test/login"},
		{"相对地址", "/user/login", port.LoginKindPage, "/user/login"},
		{"裸脚本", "var x = 1; function login(){return x}", port.LoginKindJS, "var x"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			src := sourceJSON(t, "https://demo.test", c.url, "")
			kind, payload := l.LoginKind(src)
			if kind != c.kind {
				t.Fatalf("类型应为 %s，得到 %s", c.kind, kind)
			}
			if c.want != "" && !strings.Contains(payload, c.want) {
				t.Fatalf("脚本内容应包含 %q，得到 %q", c.want, payload)
			}
			if c.kind == port.LoginKindNone && payload != "" {
				t.Fatalf("无登录方式时不该有内容: %q", payload)
			}
		})
	}
}

// 完整登录链路：脚本取表单值 → POST → Set-Cookie 落进 CookieStore → 请求自动带 Cookie。
func TestRunLoginJS(t *testing.T) {
	site := newLoginSite(t)
	src := sourceJSON(t, site.srv.URL, `@js:
		var info = source.getLoginInfoMap();
		function login() {
			java.log('正在登录 ' + info['账号']);
			var r = java.post(baseUrl + '/login', 'user=' + info['账号'] + '&pass=' + info['密码']);
			return 'posted';
		}`, "")

	l := NewLoginer("UA")
	res, err := l.RunLoginJS(context.Background(), src, mustLoginJS(t, l, src), port.LoginRunOptions{
		Info:      map[string]string{"账号": "reader", "密码": "p@ss"},
		CallLogin: true,
	})
	if err != nil {
		t.Fatalf("执行登录脚本失败: %v", err)
	}
	if site.form["user"] != "reader" || site.form["pass"] != "p@ss" {
		t.Fatalf("登录表单未按填写值提交: %#v", site.form)
	}
	if res.Cookie == "" || !strings.Contains(res.Cookie, "sid=OK") {
		t.Fatalf("Cookie 未写入: %q", res.Cookie)
	}
	if res.Output != "posted" {
		t.Fatalf("脚本返回值丢失: %q", res.Output)
	}
	if len(res.Logs) == 0 || !strings.Contains(res.Logs[0], "正在登录 reader") {
		t.Fatalf("脚本日志未回传: %#v", res.Logs)
	}

	// 用书源自己的搜索规则再请求一次，验证 Cookie 真的进了请求头。
	probe, err := l.Probe(context.Background(), src, "")
	if err != nil {
		t.Fatalf("探测失败: %v", err)
	}
	if probe.NeedLogin {
		t.Fatalf("登录后不该再被判为未登录: %#v", probe)
	}
	if !strings.Contains(site.sawCookie, "sid=OK") {
		t.Fatalf("后续请求没带上 Cookie: %q", site.sawCookie)
	}
}

// 书源忘了定义 login 函数时必须报错，而不是「执行成功但什么也没发生」。
func TestRunLoginJSRequiresLoginFunction(t *testing.T) {
	src := sourceJSON(t, "https://demo.test", "@js:var a = 1;", "")
	l := NewLoginer("UA")
	_, err := l.RunLoginJS(context.Background(), src, "var a = 1;", port.LoginRunOptions{CallLogin: true})
	if err == nil || !strings.Contains(err.Error(), "login") {
		t.Fatalf("缺少 login 函数应报错, 得到 %v", err)
	}
	if _, err := l.RunLoginJS(context.Background(), src, "  ", port.LoginRunOptions{CallLogin: true}); err == nil {
		t.Fatal("空脚本应报错")
	}
}

// 脚本用 source.putLoginHeader 保存请求头时，Cookie 要落地，上层钩子要收到原文。
func TestRunLoginJSPutLoginHeader(t *testing.T) {
	src := sourceJSON(t, "https://header.test", "@js:", "")
	l := NewLoginer("UA")
	var got string
	res, err := l.RunLoginJS(context.Background(), src,
		`function login(){ source.putLoginHeader('{"Cookie":"sid=H1","User-Agent":"X"}'); }`,
		port.LoginRunOptions{CallLogin: true, OnHeader: func(h string) error { got = h; return nil }})
	if err != nil {
		t.Fatalf("执行失败: %v", err)
	}
	if !strings.Contains(got, "sid=H1") {
		t.Fatalf("未回调上层保存登录头: %q", got)
	}
	if !strings.Contains(res.Cookie, "sid=H1") {
		t.Fatalf("Cookie 未写入: %q", res.Cookie)
	}
}

// Cookie 的写入/读取/清除都按书源域名隔离。
func TestApplyAndClearCookie(t *testing.T) {
	resetCookie(t)
	defer resetCookie(t)

	l := NewLoginer("UA")
	a := &domain.BookSource{URL: "https://a.test"}
	b := &domain.BookSource{URL: "https://b.test"}

	l.ApplyCookie(a, "sid=1")
	l.ApplyCookie(b, "sid=2")
	// 合并写：同名覆盖，不同名保留。
	l.ApplyCookie(a, "token=9; sid=3")

	if got := l.Cookie(a); !strings.Contains(got, "sid=3") || !strings.Contains(got, "token=9") {
		t.Fatalf("合并写入结果不对: %q", got)
	}
	if got := l.Cookie(b); strings.Contains(got, "token") {
		t.Fatalf("Cookie 串域了: %q", got)
	}

	l.ClearCookie(a)
	if got := l.Cookie(a); got != "" {
		t.Fatalf("清除后仍有 Cookie: %q", got)
	}
	// 空值不该把已有 Cookie 抹掉（粘贴框留空点保存时很容易发生）。
	l.ApplyCookie(b, "   ")
	if got := l.Cookie(b); got == "" {
		t.Fatal("空 Cookie 不应清除已有值")
	}
}

// 登录态探测：loginCheckJs 命中即「需要登录」，未命中即「已登录」。
func TestProbeWithLoginCheckJs(t *testing.T) {
	site := newLoginSite(t)
	// 检测脚本按原版语义：返回非空字符串说明响应被登录墙替换了。
	check := `if (result.body.indexOf('请先登录') > -1) { '登录已失效，请重新登录' } else { '' }`
	src := sourceJSON(t, site.srv.URL, "", check)
	l := NewLoginer("UA")

	probe, err := l.Probe(context.Background(), src, "")
	if err != nil {
		t.Fatalf("探测失败: %v", err)
	}
	if !probe.NeedLogin || !strings.Contains(probe.Detail, "登录已失效") {
		t.Fatalf("未登录时应命中检测脚本: %#v", probe)
	}

	l.ApplyCookie(src, "sid=OK")
	probe, err = l.Probe(context.Background(), src, "")
	if err != nil {
		t.Fatalf("探测失败: %v", err)
	}
	if probe.NeedLogin {
		t.Fatalf("已登录时不该命中: %#v", probe)
	}
	if probe.StatusCode != http.StatusOK {
		t.Fatalf("状态码应透出: %d", probe.StatusCode)
	}
}

// 没有 loginCheckJs 时退回关键词判断（结论仅是参考，但必须能识别明显的登录墙）。
func TestProbeWithoutCheckJs(t *testing.T) {
	site := newLoginSite(t)
	src := sourceJSON(t, site.srv.URL, "", "")
	l := NewLoginer("UA")

	probe, err := l.Probe(context.Background(), src, "")
	if err != nil {
		t.Fatalf("探测失败: %v", err)
	}
	if !probe.NeedLogin || !strings.Contains(probe.Detail, "请先登录") {
		t.Fatalf("应识别到登录墙: %#v", probe)
	}

	l.ApplyCookie(src, "sid=OK")
	probe, err = l.Probe(context.Background(), src, "")
	if err != nil {
		t.Fatalf("探测失败: %v", err)
	}
	if probe.NeedLogin {
		t.Fatalf("已登录时不该判为未登录: %#v", probe)
	}
}

// 探测地址缺失时要给出可读错误，而不是空指针。
func TestProbeWithoutAnyURL(t *testing.T) {
	src := &domain.BookSource{URL: "https://empty.test", Raw: `{"bookSourceUrl":"https://empty.test"}`}
	l := NewLoginer("UA")
	if _, err := l.Probe(context.Background(), src, ""); err == nil {
		t.Fatal("没有可探测地址时应报错")
	}
}

// mustLoginJS 取出书源声明里解析好的脚本正文。
func mustLoginJS(t *testing.T, l *Loginer, src *domain.BookSource) string {
	t.Helper()
	kind, payload := l.LoginKind(src)
	if kind != port.LoginKindJS {
		t.Fatalf("应判定为脚本登录，得到 %s", kind)
	}
	return payload
}

// 脚本原样返回响应（`return result`）时不能判成「需要登录」。
//
// 这是最容易踩的一处：loginCheckJs 的语义是「替换响应体」，
// 按「返回非空就算登录墙」判定的话，这类脚本会让已登录的书源永远显示未登录。
func TestProbeCheckJsReturnsSameBody(t *testing.T) {
	site := newLoginSite(t)
	src := sourceJSON(t, site.srv.URL, "", `result`)
	l := NewLoginer("UA")
	l.ApplyCookie(src, "sid=OK")

	probe, err := l.Probe(context.Background(), src, "")
	if err != nil {
		t.Fatalf("探测失败: %v", err)
	}
	if probe.NeedLogin {
		t.Fatalf("原样返回不应判为需要登录: %#v", probe)
	}
}

// 探测地址的选择：模板变量要换成具体值，JS 规则要跳过。
func TestProbeURLFor(t *testing.T) {
	src := sourceJSON(t, "https://demo.test", "", "")
	raw := `{"bookSourceUrl":"https://demo.test","searchUrl":"/search?q={{key}}&p={{page}}"}`
	src.Raw = raw
	got := probeURLFor(mustEngineSource(t, src))
	if !strings.Contains(got, "p=1") || strings.Contains(got, "{{page}}") {
		t.Fatalf("分页变量未替换: %q", got)
	}
	if strings.Contains(got, "{{key}}") || strings.Contains(got, "demo.test") && strings.Contains(got, "q=https") {
		t.Fatalf("关键词变量未替换成具体值: %q", got)
	}

	// searchUrl 是 JS 时不能拿去请求，退回 loginUrl。
	src.Raw = `{"bookSourceUrl":"https://demo.test","searchUrl":"@js:java.ajax(baseUrl)","loginUrl":"/login"}`
	if got := probeURLFor(mustEngineSource(t, src)); got != "/login" {
		t.Fatalf("JS 搜索规则应跳过，得到 %q", got)
	}

	// 只有书源地址时退回它自己。
	src.Raw = `{"bookSourceUrl":"https://demo.test"}`
	if got := probeURLFor(mustEngineSource(t, src)); got != "https://demo.test" {
		t.Fatalf("应退回书源地址，得到 %q", got)
	}
}

// mustEngineSource 把领域书源转成引擎书源（测试内部用）。
func mustEngineSource(t *testing.T, src *domain.BookSource) *legadomodel.BookSource {
	t.Helper()
	eng, err := toEngineSource(src)
	if err != nil {
		t.Fatalf("转换书源失败: %v", err)
	}
	return eng
}
