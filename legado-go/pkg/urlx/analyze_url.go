package urlx

import (
	"encoding/json"
	"fmt"
	"maps"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/legado/legado-go/pkg/debug"
	"github.com/legado/legado-go/pkg/js"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/net"
	"github.com/legado/legado-go/pkg/rule"
	"github.com/legado/legado-go/pkg/store"
	"github.com/legado/legado-go/pkg/util"
)

var (
	jsPattern      = regexp.MustCompile(`(?is)<js>([\s\S]*?)</js>|@js:([\s\S]*)`)
	pagePattern    = regexp.MustCompile(`<(.*?)>`)
	dataURIPattern = regexp.MustCompile(`^data:.*?;base64,(.*)`)
)

// Options AnalyzeUrl 构造参数
type Options struct {
	Url      string
	Key      string
	Page     *int
	BaseUrl  string
	Source   *model.BookSource
	Book     *model.Book
	Chapter  *model.BookChapter
	Headers  map[string]string
	RuleData *model.RuleData
}

// AnalyzeUrl URL 规则解析与请求（对齐 legado model/analyzeRule/AnalyzeUrl.kt）
type AnalyzeUrl struct {
	RuleUrl      string
	Url          string
	URLNoQuery   string
	HeaderMap    map[string]string
	Body         string
	Method       string
	Charset      string
	Type         string
	Retry        int
	UseWebView   bool
	WebJs        string
	ServerID     int64
	EncodedQuery string
	EncodedForm  string

	mUrl     string
	key      string
	page     *int
	baseUrl  string
	source   *model.BookSource
	book     *model.Book
	chapter  *model.BookChapter
	ruleData *model.RuleData
}

// New 创建 URL 解析器并立即解析规则
func New(opt Options) *AnalyzeUrl {
	au := &AnalyzeUrl{
		mUrl:      opt.Url,
		key:       opt.Key,
		page:      opt.Page,
		baseUrl:   opt.BaseUrl,
		source:    opt.Source,
		book:      opt.Book,
		chapter:   opt.Chapter,
		ruleData:  opt.RuleData,
		HeaderMap: map[string]string{},
		Method:    "GET",
	}
	if b, _ := splitUrlOption(opt.BaseUrl); b != "" {
		au.baseUrl = b
	}
	if opt.Headers != nil {
		maps.Copy(au.HeaderMap, opt.Headers)
	} else if opt.Source != nil {
		maps.Copy(au.HeaderMap, opt.Source.GetHeaderMap())
	}
	au.initUrl()
	return au
}

func (au *AnalyzeUrl) initUrl() {
	au.RuleUrl = au.mUrl
	au.analyzeJs()
	au.replaceKeyPageJs()
	au.analyzeUrl()
}

// analyzeJs 执行 @js: / <js></js>
func (au *AnalyzeUrl) analyzeJs() {
	start := 0
	result := au.RuleUrl
	for _, m := range jsPattern.FindAllStringSubmatchIndex(au.RuleUrl, -1) {
		if m[0] > start {
			seg := strings.TrimSpace(au.RuleUrl[start:m[0]])
			if seg != "" {
				result = strings.ReplaceAll(seg, "@result", result)
			}
		}
		code := ""
		if m[4] >= 0 {
			code = au.RuleUrl[m[4]:m[5]]
		} else if m[2] >= 0 {
			code = au.RuleUrl[m[2]:m[3]]
		}
		v := au.evalJS(code, result)
		result = ""
		if v != nil {
			result = fmt.Sprint(v)
		}
		start = m[1]
	}
	if len(au.RuleUrl) > start {
		seg := strings.TrimSpace(au.RuleUrl[start:])
		if seg != "" {
			result = strings.ReplaceAll(seg, "@result", result)
		}
	}
	au.RuleUrl = result
}

// replaceKeyPageJs 替换 {{}} 与 <1,2,3>
func (au *AnalyzeUrl) replaceKeyPageJs() {
	if strings.Contains(au.RuleUrl, "{{") && strings.Contains(au.RuleUrl, "}}") {
		replaced, ok := rule.InnerBraceReplace(au.RuleUrl, "{{", 2, 2, func(inner string) string {
			v := au.evalJS(inner, nil)
			if v == nil {
				return ""
			}
			return rule.JsToString(v)
		})
		// 与 legado 一致：整串替换结果非空才覆盖（表达式求值为空也是有效结果）
		if ok && replaced != "" {
			au.RuleUrl = replaced
		}
	}
	if au.page != nil {
		for {
			m := pagePattern.FindStringSubmatchIndex(au.RuleUrl)
			if m == nil {
				break
			}
			pages := strings.Split(au.RuleUrl[m[2]:m[3]], ",")
			val := ""
			if *au.page-1 < len(pages) && *au.page-1 >= 0 {
				val = strings.TrimSpace(pages[*au.page-1])
			} else if len(pages) > 0 {
				val = strings.TrimSpace(pages[len(pages)-1])
			}
			au.RuleUrl = au.RuleUrl[:m[0]] + val + au.RuleUrl[m[1]:]
		}
	}
}

// analyzeUrl 解析 URL 与 ",{...}" 选项
func (au *AnalyzeUrl) analyzeUrl() {
	urlNoOption, optStr := splitUrlOption(au.RuleUrl)
	au.Url = util.GetAbsoluteURL(au.baseUrl, urlNoOption)
	if b := util.GetBaseUrl(au.Url); b != "" {
		au.baseUrl = b
	}
	if optStr != "" {
		opt := parseUrlOption(optStr)
		if opt != nil {
			if m := opt.getString("method"); strings.EqualFold(m, "POST") {
				au.Method = "POST"
			}
			if hm := opt.getMap("headers"); hm != nil {
				for k, v := range hm {
					au.HeaderMap[k] = fmt.Sprint(v)
				}
			}
			if b := opt.getRaw("body"); b != nil {
				au.Body = toBodyString(b)
			}
			au.Type = opt.getString("type")
			au.Charset = opt.getString("charset")
			au.Retry = opt.getInt("retry")
			au.UseWebView = opt.getBool("webView")
			au.WebJs = opt.getString("webJs")
			au.ServerID = int64(opt.getInt("serverID"))
			if jsStr := opt.getString("js"); jsStr != "" {
				if v := au.evalJS(jsStr, au.Url); v != nil {
					au.Url = fmt.Sprint(v)
				}
			}
		}
	}
	au.URLNoQuery = au.Url
	switch au.Method {
	case "GET":
		if pos := strings.Index(au.Url, "?"); pos != -1 {
			q := au.Url[pos+1:]
			au.EncodedQuery = encodeParams(q, au.Charset, true)
			au.Url = au.Url[:pos] + "?" + au.EncodedQuery
		}
	case "POST":
		if au.Body != "" && !isJSONLike(au.Body) && !isXMLLike(au.Body) && au.HeaderMap["Content-Type"] == "" {
			au.EncodedForm = encodeParams(au.Body, au.Charset, false)
		}
	}
}

// GetStrResponse 发起请求
func (au *AnalyzeUrl) GetStrResponse() (*net.Response, error) {
	reqURL := au.Url
	body := au.Body
	contentType := au.HeaderMap["Content-Type"]
	switch au.Method {
	case "POST":
		if au.EncodedForm != "" {
			body = au.EncodedForm
		}
	default:
		body = ""
	}
	headers := map[string]string{}
	maps.Copy(headers, au.HeaderMap)
	// 从 header 中提取 proxy（legado 的约定）
	proxy := headers["proxy"]
	delete(headers, "proxy")

	saveCookie := true
	if au.source != nil {
		saveCookie = au.source.EnabledCookieJarOn()
	}
	if debug.Enabled() {
		// 先判 Enabled 再拼串，未启用时不产生字符串开销
		debug.Log(requestLine(au.Method, reqURL, body, contentType, au.Charset))
	}
	started := time.Now()
	resp, err := net.Default().Do(net.Options{
		URL:         reqURL,
		Method:      au.Method,
		Headers:     headers,
		Body:        body,
		ContentType: contentType,
		Charset:     au.Charset,
		Retry:       au.Retry,
		Proxy:       proxy,
		SaveCookie:  saveCookie,
	})
	if err != nil {
		debug.Errorf("≡请求失败 %s %s: %v", au.Method, reqURL, err)
		return nil, err
	}
	debug.Logf("≡响应 %d（%s，%s）", resp.StatusCode,
		bytesText(len(resp.Body)), time.Since(started).Round(time.Millisecond))
	if resp.URL != "" && resp.URL != reqURL {
		debug.Lines("┌重定向后地址", "└"+resp.URL)
	}
	resp.RuleURL = au.RuleUrl
	return resp, nil
}

// requestLine 生成请求摘要行。charset 单列出来是因为"GBK 没生效"是书源
// 搜索失效最常见的原因，调试时必须一眼看到。
func requestLine(method, url, body, contentType, charset string) string {
	if method == "" {
		method = "GET"
	}
	line := "≡请求 " + method + " " + url
	parts := make([]string, 0, 3)
	if body != "" {
		parts = append(parts, "body "+bytesText(len(body)))
	}
	if charset != "" {
		parts = append(parts, "charset="+charset)
	}
	if contentType != "" {
		parts = append(parts, contentType)
	}
	if len(parts) == 0 {
		return line
	}
	return line + "（" + strings.Join(parts, "，") + "）"
}

// bytesText 把字节数渲染成 512 B / 24.1 KB 这样的短串
func bytesText(n int) string {
	switch {
	case n < 1024:
		return strconv.Itoa(n) + " B"
	case n < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(n)/1024)
	}
	return fmt.Sprintf("%.1f MB", float64(n)/(1024*1024))
}

// EvalCheckJs 执行登录检测 JS（result 为 StrResponse 结构，可返回新的 body）
func (au *AnalyzeUrl) EvalCheckJs(jsStr string, resp *net.Response) string {
	if jsStr == "" || resp == nil {
		return ""
	}
	payload := map[string]any{
		"url":     resp.URL,
		"body":    resp.Body,
		"code":    resp.StatusCode,
		"headers": resp.Headers,
	}
	v := au.evalJS(jsStr, payload)
	if v == nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return t
	case map[string]any:
		if b, ok := t["body"].(string); ok {
			return b
		}
	}
	return ""
}

// GetBytes 取二进制（支持 data: URI）
func (au *AnalyzeUrl) GetBytes() ([]byte, error) {
	if strings.HasPrefix(au.URLNoQuery, "data:") {
		if m := dataURIPattern.FindStringSubmatch(au.URLNoQuery); len(m) > 1 {
			return util.Base64DecodeBytes(m[1]), nil
		}
	}
	r, err := au.GetStrResponse()
	if err != nil {
		return nil, err
	}
	return r.Bytes, nil
}

// evalJS 执行 URL 中的 JS
func (au *AnalyzeUrl) evalJS(jsStr string, result any) any {
	b := &js.Bindings{
		Source:  au.source,
		Book:    au.book,
		Chapter: au.chapter,
		Result:  result,
		BaseUrl: au.baseUrl,
		Key:     au.key,
		Page:    au.page,
		Extra:   map[string]any{"url": au.RuleUrl},
	}
	v, err := js.DefaultEngine().Eval(jsStr, b)
	if err != nil {
		js.OnLog("[AnalyzeUrl] JS 执行出错: " + err.Error())
		return nil
	}
	return v
}

// —— URL 选项 ——

// splitUrlOption 找到 ", {" 的位置并切分（RE2 无前瞻，手工扫描）
func splitUrlOption(s string) (string, string) {
	for i := 0; i < len(s); i++ {
		if s[i] == ',' {
			j := i + 1
			for j < len(s) && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
				j++
			}
			if j < len(s) && s[j] == '{' {
				return s[:i], s[j:]
			}
		}
	}
	return s, ""
}

type urlOption struct {
	raw map[string]any
}

func parseUrlOption(s string) *urlOption {
	m := map[string]any{}
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		// 宽松解析：给无引号的键补引号
		if err2 := json.Unmarshal([]byte(util.RelaxJSONKeys(s)), &m); err2 != nil {
			return nil
		}
	}
	return &urlOption{raw: m}
}

func (o *urlOption) getRaw(k string) any { return o.raw[k] }

func (o *urlOption) getString(k string) string {
	v, ok := o.raw[k]
	if !ok || v == nil {
		return ""
	}
	return fmt.Sprint(v)
}

func (o *urlOption) getInt(k string) int {
	switch t := o.raw[k].(type) {
	case float64:
		return int(t)
	case string:
		n, _ := strconv.Atoi(strings.TrimSpace(t))
		return n
	}
	return 0
}

func (o *urlOption) getBool(k string) bool {
	switch t := o.raw[k].(type) {
	case bool:
		return t
	case string:
		s := strings.ToLower(strings.TrimSpace(t))
		return s != "" && s != "false" && s != "0"
	}
	return false
}

func (o *urlOption) getMap(k string) map[string]any {
	switch t := o.raw[k].(type) {
	case map[string]any:
		return t
	case string:
		m := map[string]any{}
		if err := json.Unmarshal([]byte(t), &m); err == nil {
			return m
		}
		m2 := map[string]string{}
		if err := json.Unmarshal([]byte(t), &m2); err == nil {
			out := map[string]any{}
			for k2, v2 := range m2 {
				out[k2] = v2
			}
			return out
		}
	}
	return nil
}

func toBodyString(v any) string {
	switch t := v.(type) {
	case string:
		return t
	default:
		b, _ := json.Marshal(t)
		return string(b)
	}
}

func isJSONLike(s string) bool {
	t := strings.TrimSpace(s)
	return (strings.HasPrefix(t, "{") && strings.HasSuffix(t, "}")) ||
		(strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]"))
}

func isXMLLike(s string) bool {
	return strings.HasPrefix(strings.TrimSpace(s), "<")
}

// encodeParams 对齐 AnalyzeUrl.encodeParams
func encodeParams(params, charset string, isQuery bool) string {
	noCharset := strings.TrimSpace(charset) == ""
	cs := "utf-8"
	if strings.EqualFold(strings.TrimSpace(charset), "escape") {
		cs = "escape"
	} else if !noCharset {
		cs = util.NormalizeCharset(charset)
	}
	if isQuery && cs != "escape" {
		if util.EncodedQuery(params) {
			return params
		}
		return queryEncodeWithCharset(params, cs)
	}
	var sb strings.Builder
	pos := 0
	for pos <= len(params) {
		if sb.Len() > 0 {
			sb.WriteString("&")
		}
		amp := strings.Index(params[pos:], "&")
		if amp < 0 {
			amp = len(params) - pos
		}
		ampAbs := pos + amp
		eq := strings.Index(params[pos:], "=")
		eqAbs := -1
		if eq >= 0 {
			eqAbs = pos + eq
		}
		key := ""
		var val *string
		if eqAbs < 0 || eqAbs > ampAbs {
			key = params[pos:ampAbs]
		} else {
			key = params[pos:eqAbs]
			v := params[eqAbs+1 : ampAbs]
			val = &v
		}
		sb.WriteString(appendEncoded(key, noCharset, cs))
		if val != nil {
			sb.WriteString("=")
			sb.WriteString(appendEncoded(*val, noCharset, cs))
		}
		pos = ampAbs + 1
		if ampAbs >= len(params) {
			break
		}
	}
	return sb.String()
}

// appendEncoded 对齐 AnalyzeUrl.appendEncoded：
// charset 为空时只跳过已编码片段；charset=escape 走 escape；其余按 charset 字节百分号编码
func appendEncoded(value string, checkEncoded bool, cs string) string {
	if checkEncoded && util.EncodedForm(value) {
		return value
	}
	if cs == "escape" {
		return escapeEncode(value)
	}
	return queryEncodeWithCharset(value, cs)
}

var queryEscaper = strings.NewReplacer(
	" ", "%20", "\"", "%22", "<", "%3C", ">", "%3E",
	"'", "%27", "\\", "%5C", "^", "%5E", "`", "%60",
	"{", "%7B", "|", "%7C", "}", "%7D",
)

// queryEncode 保留 legado 约定字符集之外的字符做百分号编码
func queryEncode(s string) string {
	var sb strings.Builder
	for _, r := range s {
		if shouldKeepQuery(r) {
			sb.WriteRune(r)
			continue
		}
		if r < 0x80 {
			sb.WriteString(fmt.Sprintf("%%%02X", r))
			continue
		}
		for _, b := range []byte(string(r)) {
			sb.WriteString(fmt.Sprintf("%%%02X", b))
		}
	}
	return sb.String()
}

// queryEncodeWithCharset 先把字符串按 charset 编码成字节，再对非保留字节做百分号编码。
// 对齐 legado 的 queryEncoder.encode(params, charset)：保留字符原样输出，其余按目标编码的字节逐个 %XX。
func queryEncodeWithCharset(s, cs string) string {
	if cs == "" || cs == "utf-8" {
		return queryEncode(s)
	}
	var sb strings.Builder
	for _, b := range util.EncodeBytes(s, cs) {
		if b < 0x80 && shouldKeepQuery(rune(b)) {
			sb.WriteByte(b)
			continue
		}
		sb.WriteString(fmt.Sprintf("%%%02X", b))
	}
	return sb.String()
}

func shouldKeepQuery(r rune) bool {
	switch {
	case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		return true
	}
	return strings.ContainsRune("!$&()*+,-./:;=?@[]^_`|~", r)
}

func escapeEncode(s string) string { return queryEncode(s) }

func init() {
	// 书源请求头中的 @js / <js> 求值
	model.EvalJSHook = func(src *model.BookSource, jsStr string) string {
		v, err := js.DefaultEngine().Eval(jsStr, &js.Bindings{
			Source:  src,
			BaseUrl: src.GetKey(),
		})
		if err != nil || v == nil {
			return ""
		}
		return fmt.Sprint(v)
	}
	model.CookieStoreHook = func(u, cookie string) {
		store.Default().ReplaceCookie(u, cookie)
	}
	// 为 JS 中的 java.ajax / java.connect 提供完整的 URL 规则支持
	js.Hooks.Ajax = func(src *model.BookSource, u string) string {
		au := New(Options{Url: u, Source: src})
		r, err := au.GetStrResponse()
		if err != nil {
			return ""
		}
		return r.Body
	}
	js.Hooks.AjaxAll = func(src *model.BookSource, urls []string) []string {
		out := make([]string, 0, len(urls))
		for _, u := range urls {
			au := New(Options{Url: u, Source: src})
			r, err := au.GetStrResponse()
			if err == nil {
				out = append(out, r.Body)
			} else {
				out = append(out, "")
			}
		}
		return out
	}
	js.Hooks.Connect = func(src *model.BookSource, u string, headers map[string]string) *js.ConnectResult {
		au := New(Options{Url: u, Source: src, Headers: headers})
		r, err := au.GetStrResponse()
		if err != nil {
			return nil
		}
		return &js.ConnectResult{URL: r.URL, Body: r.Body, Code: r.StatusCode}
	}
	js.Hooks.WebView = func(src *model.BookSource, htmlStr, urlStr, jsStr string) string {
		js.OnLog("[webView] 本环境不支持内置浏览器，java.webView 已降级为空")
		return ""
	}
}
