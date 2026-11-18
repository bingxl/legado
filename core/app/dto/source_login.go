package dto

import "time"

// SourceLoginView 是书源登录面板的完整状态。
//
// 一次性给全：登录方式、要填哪些字段、已经存了什么、当前有没有登录态。
// 分开取会变成「打开对话框 → 三次往返 → 才敢渲染」，中间还会闪空表单。
type SourceLoginView struct {
	SourceID   int64  `json:"sourceId"`
	SourceName string `json:"sourceName"`
	SourceURL  string `json:"sourceUrl"`
	SourceType int    `json:"sourceType"` // 0 文本 / 1 音频 / 2 图片（漫画源）/ 3 文件

	// Kind 取值见 port.LoginKind*：none / js / page。
	Kind string `json:"kind"`
	// LoginURL 仅在 Kind=page 时有值，供前端提示「在浏览器中打开」。
	LoginURL string `json:"loginUrl"`
	// Fields 是 loginUi 解析出的登录表单；按钮按 type=button 一起给出。
	Fields []LoginFieldView `json:"fields"`
	// Info 是上次保存的表单值（用于回填）。密码以明文回填由前端决定遮罩。
	Info map[string]string `json:"info"`
	// HasCookie / CookieMask 是当前 CookieStore 里的登录态（掩码展示）。
	HasCookie  bool   `json:"hasCookie"`
	CookieMask string `json:"cookieMask"`
	// Header 是保存下来的登录请求头原文，仅在「查看」时使用。
	Header string `json:"header"`
	// CheckJS 表示书源声明了 loginCheckJs，可用于「检测登录」。
	CheckJS   bool       `json:"checkJs"`
	UpdatedAt *time.Time `json:"updatedAt"`
}

// LoginFieldView 是登录表单里的一个控件。
type LoginFieldView struct {
	Name string `json:"name"`
	// Type 为 text / password / button。
	Type string `json:"type"`
	// Action 是按钮的动作：http(s) 地址或一段 JS（对齐 RowUi.action）。
	Action string `json:"action"`
}

// LoginResult 是一次登录动作的结果。
//
// 不再用 error 表达「账号密码错」这类业务结果：登录失败时用户需要看到
// 脚本日志，而 error 只能带一句话。只有「参数不合法」才走 error。
type LoginResult struct {
	OK bool `json:"ok"`
	// LoggedIn 表示本次动作后是否拿到了 Cookie。
	LoggedIn bool   `json:"loggedIn"`
	Message  string `json:"message"`
	// Logs 是登录脚本的 java.log 输出，失败时用来告诉用户卡在哪。
	Logs []string `json:"logs"`
	// Output 是脚本返回值（少数书源用它回传提示语）。
	Output string `json:"output"`
	// OpenURL 非空时前端应打开浏览器（网页登录或按钮动作是地址）。
	OpenURL    string `json:"openUrl"`
	CookieMask string `json:"cookieMask"`
}

// LoginProbeView 是登录态探测结果。
//
// 没有 loginCheckJs 的书源只能靠关键词/状态码判断，结论仅供参考，
// 因此把判定依据（Detail）一起给前端展示，避免用户被一个武断的结论误导。
type LoginProbeView struct {
	NeedLogin  bool   `json:"needLogin"`
	Detail     string `json:"detail"`
	StatusCode int    `json:"statusCode"`
	URL        string `json:"url"`
}
