package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ── 替身 ────────────────────────────────────────────────────

// fakeLoginSources 只实现 Get：登录服务不碰其它仓储方法。
type fakeLoginSources struct {
	port.BookSourceRepository
	src *domain.BookSource
	err error
}

func (f fakeLoginSources) Get(context.Context, int64) (*domain.BookSource, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.src, nil
}

// fakeLoginRepo 是内存版登录信息仓储。
type fakeLoginRepo struct {
	items   map[string]domain.SourceLogin
	saves   int
	deletes int
}

func newFakeLoginRepo() *fakeLoginRepo {
	return &fakeLoginRepo{items: map[string]domain.SourceLogin{}}
}

func (r *fakeLoginRepo) Get(_ context.Context, sourceURL string) (domain.SourceLogin, error) {
	v, ok := r.items[sourceURL]
	if !ok {
		return domain.SourceLogin{}, fmt.Errorf("%w: 没有登录信息", domain.ErrNotFound)
	}
	return v, nil
}

func (r *fakeLoginRepo) Save(_ context.Context, login domain.SourceLogin) error {
	r.saves++
	// 与真实仓储一致：没给时间就补当前时间（界面靠它显示「上次登录」）。
	if login.UpdatedAt.IsZero() {
		login.UpdatedAt = time.Now()
	}
	r.items[login.SourceURL] = login
	return nil
}

func (r *fakeLoginRepo) Delete(_ context.Context, sourceURL string) error {
	r.deletes++
	delete(r.items, sourceURL)
	return nil
}

func (r *fakeLoginRepo) ListSourceURLs(context.Context) ([]string, error) {
	out := make([]string, 0, len(r.items))
	for k := range r.items {
		out = append(out, k)
	}
	return out, nil
}

// fakeLoginer 是引擎登录能力的替身：脚本用「回调」模拟，
// 这样不必为了测业务分支去起 HTTP 服务。
type fakeLoginer struct {
	kind    string
	payload string

	cookie  string
	applied []string
	cleared int

	runErr error
	run    func(opt port.LoginRunOptions, script string) port.LoginScriptResult

	probe    port.LoginProbe
	probeErr error

	lastScript string
	lastOpt    port.LoginRunOptions
}

func (f *fakeLoginer) LoginKind(*domain.BookSource) (string, string) {
	return f.kind, f.payload
}

func (f *fakeLoginer) RunLoginJS(_ context.Context, _ *domain.BookSource, script string, opt port.LoginRunOptions) (port.LoginScriptResult, error) {
	f.lastScript = script
	f.lastOpt = opt
	if f.runErr != nil {
		return port.LoginScriptResult{Logs: []string{"脚本炸了"}}, f.runErr
	}
	if f.run != nil {
		return f.run(opt, script), nil
	}
	return port.LoginScriptResult{Cookie: f.cookie}, nil
}

func (f *fakeLoginer) Cookie(*domain.BookSource) string { return f.cookie }

func (f *fakeLoginer) ApplyCookie(_ *domain.BookSource, cookie string) {
	f.applied = append(f.applied, cookie)
	f.cookie = cookie
}

func (f *fakeLoginer) ClearCookie(*domain.BookSource) {
	f.cleared++
	f.cookie = ""
}

func (f *fakeLoginer) Probe(context.Context, *domain.BookSource, string) (port.LoginProbe, error) {
	return f.probe, f.probeErr
}

// ── 测试辅助 ────────────────────────────────────────────────

func loginSource(t *testing.T, raw map[string]any) *domain.BookSource {
	t.Helper()
	if raw == nil {
		raw = map[string]any{}
	}
	if _, ok := raw["bookSourceUrl"]; !ok {
		raw["bookSourceUrl"] = "https://demo.test"
	}
	if _, ok := raw["bookSourceName"]; !ok {
		raw["bookSourceName"] = "演示源"
	}
	b := mustJSON(t, raw)
	return &domain.BookSource{ID: 7, Name: "演示源", URL: "https://demo.test", Raw: b, Enabled: true}
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("序列化失败: %v", err)
	}
	return string(b)
}

// newLoginEnv 组装一套登录服务与它的替身。
func newLoginEnv(t *testing.T, src *domain.BookSource) (*SourceLoginService, *fakeLoginRepo, *fakeLoginer) {
	t.Helper()
	if src == nil {
		src = loginSource(t, nil)
	}
	repo := newFakeLoginRepo()
	engine := &fakeLoginer{kind: port.LoginKindNone}
	svc := NewSourceLoginService(SourceLoginDeps{
		Sources: fakeLoginSources{src: src},
		Logins:  repo,
		Engine:  engine,
	})
	return svc, repo, engine
}

// ── Profile ────────────────────────────────────────────────

func TestSourceLoginProfile(t *testing.T) {
	src := loginSource(t, map[string]any{
		"bookSourceType": 2, // 漫画源
		"loginUrl":       "@js: function login(){java.post(baseUrl+'/login','a=1')}",
		"loginUi":        `[{"name":"账号","type":"text"},{"name":"密码","type":"password"}]`,
		"loginCheckJs":   "@js: ''",
	})
	svc, repo, engine := newLoginEnv(t, src)
	engine.kind = port.LoginKindJS
	engine.cookie = "sid=abcdefgh; token=9999"
	if err := repo.Save(context.Background(), domain.SourceLogin{
		SourceURL: src.URL,
		Form:      map[string]string{"账号": "reader"},
		Header:    `{"Cookie":"sid=abcdefgh"}`,
	}); err != nil {
		t.Fatalf("准备登录信息失败: %v", err)
	}

	view, err := svc.Profile(context.Background(), 7)
	if err != nil {
		t.Fatalf("读取登录配置失败: %v", err)
	}
	if view.SourceType != 2 {
		t.Fatalf("漫画源类型未透出: %d", view.SourceType)
	}
	if view.Kind != port.LoginKindJS {
		t.Fatalf("登录方式错误: %s", view.Kind)
	}
	if len(view.Fields) != 2 || view.Fields[1].Type != "password" {
		t.Fatalf("表单字段解析错误: %#v", view.Fields)
	}
	if view.Info["账号"] != "reader" {
		t.Fatalf("已保存的表单值未回填: %#v", view.Info)
	}
	if !view.HasCookie || !strings.Contains(view.CookieMask, "sid=") {
		t.Fatalf("登录态未反映: %#v", view)
	}
	if strings.Contains(view.CookieMask, "9999") {
		t.Fatalf("掩码泄露了完整 Cookie: %q", view.CookieMask)
	}
	if !view.CheckJS {
		t.Fatal("loginCheckJs 未识别")
	}
	if view.UpdatedAt == nil {
		t.Fatal("更新时间未透出")
	}
}

// 网页登录：要把相对地址补成绝对地址，前端才能直接打开。
func TestSourceLoginProfilePageKind(t *testing.T) {
	src := loginSource(t, map[string]any{"loginUrl": "/user/login"})
	svc, _, engine := newLoginEnv(t, src)
	engine.kind = port.LoginKindPage
	engine.payload = "/user/login"

	view, err := svc.Profile(context.Background(), 7)
	if err != nil {
		t.Fatalf("读取失败: %v", err)
	}
	if view.LoginURL != "https://demo.test/user/login" {
		t.Fatalf("登录页地址未补全: %q", view.LoginURL)
	}
	if view.HasCookie || view.CookieMask != "" {
		t.Fatalf("未登录时不该有 Cookie: %#v", view)
	}
}

func TestSourceLoginProfileInvalidID(t *testing.T) {
	svc, _, _ := newLoginEnv(t, nil)
	if _, err := svc.Profile(context.Background(), 0); !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("ID 为 0 应报参数错误, 得到 %v", err)
	}
	if _, err := svc.Profile(context.Background(), 7); err != nil {
		t.Fatalf("正常读取不应失败: %v", err)
	}
}

// 没有 raw（导入异常或新建未保存）也要能打开面板，只是「没有登录方式」。
func TestSourceLoginProfileEmptyRaw(t *testing.T) {
	svc, _, _ := newLoginEnv(t, &domain.BookSource{ID: 7, Name: "空源", URL: "https://demo.test"})
	view, err := svc.Profile(context.Background(), 7)
	if err != nil {
		t.Fatalf("读取失败: %v", err)
	}
	if view.Kind != port.LoginKindNone || len(view.Fields) != 0 {
		t.Fatalf("空源不该有登录配置: %#v", view)
	}
}

// ── Login ──────────────────────────────────────────────────

func TestSourceLoginNoneKind(t *testing.T) {
	svc, _, engine := newLoginEnv(t, nil)
	engine.kind = port.LoginKindNone

	res, err := svc.Login(context.Background(), 7, map[string]string{"账号": "x"})
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if res.OK || !strings.Contains(res.Message, "粘贴") {
		t.Fatalf("应提示手动粘贴: %#v", res)
	}
}

func TestSourceLoginPageKind(t *testing.T) {
	svc, repo, engine := newLoginEnv(t, nil)
	engine.kind = port.LoginKindPage
	engine.payload = "https://demo.test/login?from=app"

	res, err := svc.Login(context.Background(), 7, nil)
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if res.OpenURL != "https://demo.test/login?from=app" {
		t.Fatalf("应返回登录页地址: %#v", res)
	}
	if len(repo.items) != 0 {
		t.Fatalf("网页登录不该写登录信息: %#v", repo.items)
	}
}

// 脚本登录成功：要先落表单、再执行 login()、最后把 Cookie 与登录头存下来。
func TestSourceLoginSucceed(t *testing.T) {
	svc, repo, engine := newLoginEnv(t, nil)
	engine.kind = port.LoginKindJS
	engine.payload = "function login(){ java.post(baseUrl+'/login','a=1') }"
	engine.cookie = "before=1"
	engine.run = func(opt port.LoginRunOptions, script string) port.LoginScriptResult {
		if !opt.CallLogin {
			t.Error("登录按钮必须调用 login()")
		}
		if opt.Info["账号"] != "reader" {
			t.Errorf("表单值未传给脚本: %#v", opt.Info)
		}
		if opt.OnHeader != nil {
			_ = opt.OnHeader(`{"Cookie":"sid=fresh"}`)
		}
		return port.LoginScriptResult{
			Cookie: "before=1; sid=fresh",
			Output: "ok",
			Logs:   []string{"[js.log] 登录中"},
		}
	}

	res, err := svc.Login(context.Background(), 7, map[string]string{"账号": "reader", "密码": "p@ss"})
	if err != nil {
		t.Fatalf("登录失败: %v", err)
	}
	if !res.OK || !res.LoggedIn {
		t.Fatalf("应登录成功: %#v", res)
	}
	if len(res.Logs) != 1 || res.Output != "ok" {
		t.Fatalf("日志/输出未回传: %#v", res)
	}
	saved := repo.items["https://demo.test"]
	if saved.Form["账号"] != "reader" {
		t.Fatalf("表单值未保存: %#v", saved)
	}
	if !strings.Contains(saved.Header, "sid=fresh") {
		t.Fatalf("登录头未保存: %q", saved.Header)
	}
}

// 脚本跑完但 Cookie 没变：多半脚本没真的发请求，必须提示而不是报成功。
func TestSourceLoginNoCookieChange(t *testing.T) {
	svc, _, engine := newLoginEnv(t, nil)
	engine.kind = port.LoginKindJS
	engine.payload = "function login(){}"
	engine.cookie = "same=1"
	engine.run = func(port.LoginRunOptions, string) port.LoginScriptResult {
		return port.LoginScriptResult{Cookie: "same=1"}
	}

	res, err := svc.Login(context.Background(), 7, nil)
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if res.OK {
		t.Fatalf("Cookie 未变化时不该报成功: %#v", res)
	}
	if !strings.Contains(res.Message, "没有变化") {
		t.Fatalf("提示不准确: %q", res.Message)
	}
}

// 空表单时（脚本自带账号）第一次拿到 Cookie 就算成功。
func TestSourceLoginFirstCookie(t *testing.T) {
	svc, _, engine := newLoginEnv(t, nil)
	engine.kind = port.LoginKindJS
	engine.payload = "function login(){}"
	engine.run = func(port.LoginRunOptions, string) port.LoginScriptResult {
		return port.LoginScriptResult{Cookie: "sid=new"}
	}
	res, err := svc.Login(context.Background(), 7, nil)
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if !res.OK || !strings.Contains(res.CookieMask, "sid=") {
		t.Fatalf("应报成功并给出掩码: %#v", res)
	}
}

// 脚本抛错：把日志一起返回，但不作为 Go error（前端要展示日志）。
func TestSourceLoginScriptError(t *testing.T) {
	svc, repo, engine := newLoginEnv(t, nil)
	engine.kind = port.LoginKindJS
	engine.payload = "function login(){ throw 'x' }"
	engine.runErr = errors.New("账号或密码错误")

	res, err := svc.Login(context.Background(), 7, map[string]string{"账号": "a"})
	if err != nil {
		t.Fatalf("脚本错误不该变成调用错误: %v", err)
	}
	if res.OK {
		t.Fatalf("失败时不该报成功: %#v", res)
	}
	if !strings.Contains(res.Message, "账号或密码错误") || len(res.Logs) == 0 {
		t.Fatalf("错误信息或日志缺失: %#v", res)
	}
	// 表单仍要存下来，方便用户改密码重试。
	if repo.items["https://demo.test"].Form["账号"] != "a" {
		t.Fatalf("失败也应保存表单: %#v", repo.items)
	}
}

// 没有 Cookie 且脚本没输出：给出可操作的提示。
func TestSourceLoginNoCookieNoOutput(t *testing.T) {
	svc, _, engine := newLoginEnv(t, nil)
	engine.kind = port.LoginKindJS
	engine.payload = "function login(){}"
	engine.run = func(port.LoginRunOptions, string) port.LoginScriptResult {
		return port.LoginScriptResult{}
	}
	res, _ := svc.Login(context.Background(), 7, nil)
	if res.OK || !strings.Contains(res.Message, "验证码") {
		t.Fatalf("提示不准确: %#v", res)
	}
}

// 脚本有输出但没 Cookie：把输出当失败原因透出（很多源就是这么提示密码错的）。
func TestSourceLoginOutputAsReason(t *testing.T) {
	svc, _, engine := newLoginEnv(t, nil)
	engine.kind = port.LoginKindJS
	engine.payload = "function login(){}"
	engine.run = func(port.LoginRunOptions, string) port.LoginScriptResult {
		return port.LoginScriptResult{Output: "验证码错误"}
	}
	res, _ := svc.Login(context.Background(), 7, nil)
	if res.OK || !strings.Contains(res.Message, "验证码错误") {
		t.Fatalf("脚本输出应作为原因: %#v", res)
	}
}

// ── RunAction ──────────────────────────────────────────────

func TestSourceLoginRunActionURL(t *testing.T) {
	svc, _, engine := newLoginEnv(t, nil)
	engine.kind = port.LoginKindJS
	engine.payload = "function login(){}"

	res, err := svc.RunAction(context.Background(), 7, "/user/register", nil)
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if res.OpenURL != "https://demo.test/user/register" {
		t.Fatalf("按钮地址未补全: %#v", res)
	}
	if engine.lastScript != "" {
		t.Fatalf("地址型按钮不该执行脚本: %q", engine.lastScript)
	}
}

// 按钮脚本要拼在登录脚本后面执行，且不能调用 login()，result 里带表单值。
func TestSourceLoginRunActionScript(t *testing.T) {
	svc, _, engine := newLoginEnv(t, nil)
	engine.kind = port.LoginKindJS
	engine.payload = "function helper(){ return 1 }"

	res, err := svc.RunAction(context.Background(), 7, "java.post(baseUrl+'/sms', result['账号'])", map[string]string{"账号": "reader"})
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if !strings.Contains(engine.lastScript, "function helper") || !strings.Contains(engine.lastScript, "/sms") {
		t.Fatalf("按钮脚本未与登录脚本拼接: %q", engine.lastScript)
	}
	if engine.lastOpt.CallLogin {
		t.Fatal("按钮脚本不能调用 login()")
	}
	if engine.lastOpt.Result["账号"] != "reader" {
		t.Fatalf("表单值未放进 result: %#v", engine.lastOpt.Result)
	}
	if !res.OK {
		t.Fatalf("应报成功: %#v", res)
	}
}

func TestSourceLoginRunActionEmpty(t *testing.T) {
	svc, _, _ := newLoginEnv(t, nil)
	res, err := svc.RunAction(context.Background(), 7, "  ", nil)
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if res.OK || res.Message == "" {
		t.Fatalf("空动作应给出提示: %#v", res)
	}
}

// ── 手动 Cookie ────────────────────────────────────────────

func TestSourceLoginSaveHeader(t *testing.T) {
	svc, repo, engine := newLoginEnv(t, nil)

	res, err := svc.SaveHeader(context.Background(), 7, "Cookie: sid=abc; token=1")
	if err != nil {
		t.Fatalf("保存失败: %v", err)
	}
	if !res.OK || !res.LoggedIn {
		t.Fatalf("应报成功: %#v", res)
	}
	if len(engine.applied) != 1 || !strings.Contains(engine.applied[0], "sid=abc") {
		t.Fatalf("Cookie 未写入引擎: %#v", engine.applied)
	}
	saved := repo.items["https://demo.test"]
	if !strings.Contains(saved.Header, `"Cookie":"sid=abc; token=1"`) {
		t.Fatalf("登录头未规范化保存: %q", saved.Header)
	}
}

// 只粘裸 Cookie 也要认。
func TestSourceLoginSaveHeaderBareCookie(t *testing.T) {
	svc, _, engine := newLoginEnv(t, nil)
	if _, err := svc.SaveHeader(context.Background(), 7, "sid=xyz"); err != nil {
		t.Fatalf("保存失败: %v", err)
	}
	if engine.applied[0] != "sid=xyz" {
		t.Fatalf("裸 Cookie 未应用: %#v", engine.applied)
	}
}

// 没有 Cookie 的内容要明确报错，不能默默存一条空记录。
func TestSourceLoginSaveHeaderWithoutCookie(t *testing.T) {
	svc, repo, _ := newLoginEnv(t, nil)
	_, err := svc.SaveHeader(context.Background(), 7, `{"User-Agent":"UA"}`)
	if !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("应报参数错误, 得到 %v", err)
	}
	if len(repo.items) != 0 {
		t.Fatalf("失败时不该写库: %#v", repo.items)
	}
}

func TestSourceLoginHeader(t *testing.T) {
	svc, repo, _ := newLoginEnv(t, nil)
	got, err := svc.Header(context.Background(), 7)
	if err != nil {
		t.Fatalf("读取失败: %v", err)
	}
	if got != "" {
		t.Fatalf("没有记录时应为空: %q", got)
	}

	_ = repo.Save(context.Background(), domain.SourceLogin{SourceURL: "https://demo.test", Header: `{"Cookie":"a=1"}`})
	got, _ = svc.Header(context.Background(), 7)
	if got != `{"Cookie":"a=1"}` {
		t.Fatalf("登录头读取错误: %q", got)
	}
}

// ── 清除 ──────────────────────────────────────────────────

// 只清登录态时，账号密码要保留（换号重登不用重敲）。
func TestSourceLoginClearKeepForm(t *testing.T) {
	svc, repo, engine := newLoginEnv(t, nil)
	_ = repo.Save(context.Background(), domain.SourceLogin{
		SourceURL: "https://demo.test",
		Form:      map[string]string{"账号": "reader"},
		Header:    `{"Cookie":"a=1"}`,
	})

	if err := svc.Clear(context.Background(), 7, false); err != nil {
		t.Fatalf("清除失败: %v", err)
	}
	if engine.cleared != 1 {
		t.Fatalf("Cookie 未清除: %d", engine.cleared)
	}
	saved := repo.items["https://demo.test"]
	if saved.Header != "" {
		t.Fatalf("登录头未清除: %q", saved.Header)
	}
	if saved.Form["账号"] != "reader" {
		t.Fatalf("表单值不该被清: %#v", saved.Form)
	}
}

// 连表单一起清：整条记录删掉，不留空行。
func TestSourceLoginClearWithForm(t *testing.T) {
	svc, repo, engine := newLoginEnv(t, nil)
	_ = repo.Save(context.Background(), domain.SourceLogin{
		SourceURL: "https://demo.test",
		Form:      map[string]string{"账号": "reader"},
		Header:    `{"Cookie":"a=1"}`,
	})
	if err := svc.Clear(context.Background(), 7, true); err != nil {
		t.Fatalf("清除失败: %v", err)
	}
	if _, ok := repo.items["https://demo.test"]; ok {
		t.Fatal("记录应被删除")
	}
	if engine.cleared != 1 {
		t.Fatal("Cookie 未清除")
	}
}

// 没有记录时清除也要成功（按钮可能被连点两次）。
func TestSourceLoginClearMissing(t *testing.T) {
	svc, repo, _ := newLoginEnv(t, nil)
	if err := svc.Clear(context.Background(), 7, false); err != nil {
		t.Fatalf("清除不存在的记录应幂等: %v", err)
	}
	if repo.deletes != 0 {
		t.Fatalf("不该产生删除调用: %d", repo.deletes)
	}
}

// ── 检测 ──────────────────────────────────────────────────

func TestSourceLoginCheck(t *testing.T) {
	svc, _, engine := newLoginEnv(t, nil)
	engine.probe = port.LoginProbe{NeedLogin: true, Detail: "命中登录墙", StatusCode: 200, URL: "https://demo.test/search"}

	view, err := svc.Check(context.Background(), 7, "")
	if err != nil {
		t.Fatalf("检测失败: %v", err)
	}
	if !view.NeedLogin || view.Detail != "命中登录墙" || view.StatusCode != 200 {
		t.Fatalf("检测结果未透出: %#v", view)
	}

	engine.probeErr = errors.New("网络不通")
	if _, err := svc.Check(context.Background(), 7, ""); err == nil {
		t.Fatal("探测失败应报错")
	}
}

// ── 纯函数 ────────────────────────────────────────────────

func TestParseLoginFields(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []dto.LoginFieldView
	}{
		{"空", "", nil},
		{"null", "null", nil},
		{"非法 JSON", "{oops", nil},
		{
			"标准数组",
			`[{"name":"账号","type":"text"},{"name":"密码","type":"password"},{"name":"注册","type":"button","action":"https://x.test/reg"}]`,
			[]dto.LoginFieldView{
				{Name: "账号", Type: "text"},
				{Name: "密码", Type: "password"},
				{Name: "注册", Type: "button", Action: "https://x.test/reg"},
			},
		},
		{
			"字符串化的数组",
			`"[{\"name\":\"手机\",\"type\":\"text\"}]"`,
			[]dto.LoginFieldView{{Name: "手机", Type: "text"}},
		},
		{
			"默认 type 与未知 type",
			`[{"name":"a"},{"name":"b","type":"switch"},{"name":""},{"name":"c","type":"PASSWORD"}]`,
			[]dto.LoginFieldView{{Name: "a", Type: "text"}, {Name: "c", Type: "password"}},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := parseLoginFields(c.in)
			if len(got) != len(c.want) {
				t.Fatalf("字段数不对: %#v", got)
			}
			for i := range got {
				if got[i] != c.want[i] {
					t.Fatalf("第 %d 项不对: %#v 期望 %#v", i, got[i], c.want[i])
				}
			}
		})
	}
}

func TestIsURLAndAbsolute(t *testing.T) {
	for _, s := range []string{"https://a.test/x", "http://a.test", "/x", "./x", "../x"} {
		if !isURL(s) {
			t.Fatalf("%q 应识别为地址", s)
		}
	}
	for _, s := range []string{"java.post('a','b')", "var x = 1", ""} {
		if isURL(s) {
			t.Fatalf("%q 不该识别为地址", s)
		}
	}

	cases := []struct{ base, ref, want string }{
		{"https://a.test", "/login", "https://a.test/login"},
		{"https://a.test/read/", "login", "https://a.test/read/login"},
		{"https://a.test", "https://b.test/x", "https://b.test/x"},
		{"https://a.test", "", ""},
		{"", "/login", "/login"},
	}
	for _, c := range cases {
		if got := absoluteURL(c.base, c.ref); got != c.want {
			t.Fatalf("absoluteURL(%q,%q) = %q，期望 %q", c.base, c.ref, got, c.want)
		}
	}
}
