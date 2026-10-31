package js

import (
	"archive/zip"
	"bytes"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/dop251/goja"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/net"
	"github.com/legado/legado-go/pkg/store"
	"github.com/legado/legado-go/pkg/util"
	"golang.org/x/net/html"
)

// OnLog JS 输出回调，可由宿主覆盖
var OnLog = func(msg string) {}

// FileRoot JS 文件操作的根目录（相对路径均基于此）
var FileRoot = "./cache"

// VarStore 变量读写接口（由 AnalyzeRule 实现）
type VarStore interface {
	Put(key, value string) string
	Get(key string) string
}

// ConnectResult java.connect 返回结构
type ConnectResult struct {
	URL  string
	Body string
	Code int
}

// Hooks 由上层（AnalyzeUrl）注册，实现完整的 URL 规则支持
var Hooks struct {
	Ajax      func(src *model.BookSource, u string) string
	AjaxAll   func(src *model.BookSource, urls []string) []*ConnectResult
	Connect   func(src *model.BookSource, u string, headers map[string]string) *ConnectResult
	WebView   func(src *model.BookSource, htmlStr, urlStr, jsStr string) string
	GetCookie func(u string) string
	SetCookie func(u, cookie string)
	// ReGetBook / RefreshTocUrl 供 preUpdateJs 里的 java.reGetBook /
	// java.refreshTocUrl 回调（实现放在 webbook，避免 js ↔ webbook 循环依赖）
	ReGetBook     func(src *model.BookSource, book *model.Book) error
	RefreshTocUrl func(src *model.BookSource, book *model.Book) error
	// URLType 取 URL 规则里的 type 选项（java.downloadFile(content, url) 用）
	URLType func(src *model.BookSource, u string) string
}

func Md5(s string) string {
	h := md5.Sum([]byte(s))
	return hex.EncodeToString(h[:])
}

// —— HTML 节点包装（JS 中作为 jsoup Element/Elements 使用）——

// ElementWrap 把 *html.Node 包装成可在 JS 中调用的类 jsoup 对象
type ElementWrap struct {
	node *html.Node
}

func NewElementWrap(n *html.Node) *ElementWrap { return &ElementWrap{n} }

func (e *ElementWrap) Node() *html.Node {
	if e == nil {
		return nil
	}
	return e.node
}

func WrapNodes(ns []*html.Node) []*ElementWrap {
	out := make([]*ElementWrap, 0, len(ns))
	for _, n := range ns {
		out = append(out, &ElementWrap{n})
	}
	return out
}

func (e *ElementWrap) Object(vm *goja.Runtime) *goja.Object {
	o := vm.NewObject()
	o.Set("select", func(call goja.FunctionCall) goja.Value {
		css := fmt.Sprint(exportValue(call.Argument(0)))
		return toJSValue(vm, WrapNodes(util.Select(e.node, css)))
	})
	o.Set("attr", func(call goja.FunctionCall) goja.Value {
		name := fmt.Sprint(exportValue(call.Argument(0)))
		switch strings.ToLower(name) {
		case "abs:href", "abs:src":
			base := "href"
			if strings.HasSuffix(name, "src") {
				base = "src"
			}
			v := util.NodeAttr(e.node, base)
			if len(call.Arguments) > 1 {
				v = util.GetAbsoluteURL(fmt.Sprint(exportValue(call.Argument(1))), v)
			}
			return vm.ToValue(v)
		case "html", "outerHtml":
			return vm.ToValue(util.Render(e.node))
		case "text":
			return vm.ToValue(util.NodeTextNorm(e.node))
		}
		return vm.ToValue(util.NodeAttr(e.node, name))
	})
	o.Set("text", func(goja.FunctionCall) goja.Value { return vm.ToValue(util.NodeTextNorm(e.node)) })
	o.Set("ownText", func(goja.FunctionCall) goja.Value { return vm.ToValue(util.NodeOwnTextNorm(e.node)) })
	o.Set("html", func(goja.FunctionCall) goja.Value { return vm.ToValue(util.InnerHTML(e.node)) })
	o.Set("outerHtml", func(goja.FunctionCall) goja.Value { return vm.ToValue(util.Render(e.node)) })
	o.Set("toString", func(goja.FunctionCall) goja.Value { return vm.ToValue(util.Render(e.node)) })
	o.Set("tagName", func(goja.FunctionCall) goja.Value { return vm.ToValue(strings.ToLower(e.node.Data)) })
	o.Set("className", func(goja.FunctionCall) goja.Value { return vm.ToValue(util.NodeAttr(e.node, "class")) })
	o.Set("id", func(goja.FunctionCall) goja.Value { return vm.ToValue(util.NodeAttr(e.node, "id")) })
	o.Set("parent", func(goja.FunctionCall) goja.Value {
		if e.node.Parent != nil {
			return toJSValue(vm, &ElementWrap{e.node.Parent})
		}
		return goja.Null()
	})
	// parentNode 是 jsoup Node 上的同义方法。书源 JS 里非常常见的是
	// `result.parentNode().parentNode()...`（逐级上溯到包含章节标题的容器），
	// 早期只提供了 parent，导致这类规则抛「parentNode is not a function」，
	// 章节名取空 → 整本书解析出 0 章。
	o.Set("parentNode", func(goja.FunctionCall) goja.Value {
		if e.node.Parent != nil {
			return toJSValue(vm, &ElementWrap{e.node.Parent})
		}
		return goja.Null()
	})
	// selectFirst 对应 jsoup Element#selectFirst
	o.Set("selectFirst", func(call goja.FunctionCall) goja.Value {
		css := fmt.Sprint(exportValue(call.Argument(0)))
		if ns := util.Select(e.node, css); len(ns) > 0 {
			return toJSValue(vm, &ElementWrap{ns[0]})
		}
		return goja.Null()
	})
	// getElementsByClass / getElementsByTag / getElementById：jsoup 传统 API
	o.Set("getElementsByClass", func(call goja.FunctionCall) goja.Value {
		cls := strings.TrimSpace(fmt.Sprint(exportValue(call.Argument(0))))
		if cls == "" {
			return toJSValue(vm, WrapNodes(nil))
		}
		return toJSValue(vm, WrapNodes(util.Select(e.node, "."+strings.ReplaceAll(cls, " ", "."))))
	})
	o.Set("getElementsByTag", func(call goja.FunctionCall) goja.Value {
		tag := strings.ToLower(strings.TrimSpace(fmt.Sprint(exportValue(call.Argument(0)))))
		return toJSValue(vm, WrapNodes(util.Select(e.node, tag)))
	})
	o.Set("getElementById", func(call goja.FunctionCall) goja.Value {
		id := strings.TrimSpace(fmt.Sprint(exportValue(call.Argument(0))))
		if id == "" {
			return goja.Null()
		}
		if ns := util.Select(e.node, "#"+id); len(ns) > 0 {
			return toJSValue(vm, &ElementWrap{ns[0]})
		}
		return goja.Null()
	})
	// allElements 返回子树内所有元素（jsoup Element#allElements）
	o.Set("allElements", func(goja.FunctionCall) goja.Value {
		return toJSValue(vm, WrapNodes(util.Descendants(e.node)))
	})
	o.Set("hasClass", func(call goja.FunctionCall) goja.Value {
		cls := strings.TrimSpace(fmt.Sprint(exportValue(call.Argument(0))))
		return vm.ToValue(slices.Contains(strings.Fields(util.NodeAttr(e.node, "class")), cls))
	})
	o.Set("classNames", func(goja.FunctionCall) goja.Value {
		cls := util.NodeAttr(e.node, "class")
		return vm.ToValue(strings.Fields(cls))
	})
	o.Set("absUrl", func(call goja.FunctionCall) goja.Value {
		name := fmt.Sprint(exportValue(call.Argument(0)))
		return vm.ToValue(util.GetAbsoluteURL("", util.NodeAttr(e.node, name)))
	})
	o.Set("elementSiblingIndex", func(goja.FunctionCall) goja.Value {
		i := 0
		for n := e.node.PrevSibling; n != nil; n = n.PrevSibling {
			if n.Type == html.ElementNode {
				i++
			}
		}
		return vm.ToValue(i)
	})
	o.Set("siblingIndex", func(goja.FunctionCall) goja.Value {
		i := 0
		for n := e.node.PrevSibling; n != nil; n = n.PrevSibling {
			i++
		}
		return vm.ToValue(i)
	})
	o.Set("previousElementSibling", func(goja.FunctionCall) goja.Value {
		for n := e.node.PrevSibling; n != nil; n = n.PrevSibling {
			if n.Type == html.ElementNode {
				return toJSValue(vm, &ElementWrap{n})
			}
		}
		return goja.Null()
	})
	o.Set("children", func(goja.FunctionCall) goja.Value {
		return toJSValue(vm, WrapNodes(util.ChildElements(e.node)))
	})
	o.Set("next", func(goja.FunctionCall) goja.Value {
		n := e.node.NextSibling
		for n != nil && n.Type != html.ElementNode {
			n = n.NextSibling
		}
		if n == nil {
			return goja.Null()
		}
		return toJSValue(vm, &ElementWrap{n})
	})
	o.Set("nextElementSibling", func(goja.FunctionCall) goja.Value {
		n := e.node.NextSibling
		for n != nil && n.Type != html.ElementNode {
			n = n.NextSibling
		}
		if n == nil {
			return goja.Null()
		}
		return toJSValue(vm, &ElementWrap{n})
	})
	o.Set("textNodes", func(goja.FunctionCall) goja.Value {
		arr := make([]any, 0)
		for _, s := range util.NodeTextNodes(e.node) {
			arr = append(arr, s)
		}
		return vm.ToValue(arr)
	})
	o.Set("data", func(goja.FunctionCall) goja.Value { return vm.ToValue(util.NodeText(e.node)) })
	return o
}

// Elements 模拟 jsoup 的 Elements：本身是 JS 数组，另带 text/attr/size/get 等方法。
// 书源里大量使用 `result.select('x').text()` 这种写法，只返回裸数组会直接报
// "Object has no member 'text'"。
func elementsObject(vm *goja.Runtime, list []*ElementWrap) *goja.Object {
	vals := make([]any, 0, len(list))
	for _, e := range list {
		vals = append(vals, e.Object(vm))
	}
	obj := vm.NewArray(vals...)
	texts := func() string {
		parts := make([]string, 0, len(list))
		for _, e := range list {
			if t := util.NodeTextNorm(e.node); t != "" {
				parts = append(parts, t)
			}
		}
		return strings.Join(parts, " ")
	}
	obj.Set("text", func(goja.FunctionCall) goja.Value { return vm.ToValue(texts()) })
	obj.Set("attr", func(call goja.FunctionCall) goja.Value {
		name := fmt.Sprint(exportValue(call.Argument(0)))
		switch strings.ToLower(name) {
		case "abs:href", "abs:src":
			base := "href"
			if strings.HasSuffix(name, "src") {
				base = "src"
			}
			v := ""
			if len(list) > 0 {
				v = util.NodeAttr(list[0].node, base)
			}
			if len(call.Arguments) > 1 {
				v = util.GetAbsoluteURL(fmt.Sprint(exportValue(call.Argument(1))), v)
			}
			return vm.ToValue(v)
		case "html", "outerHtml":
			if len(list) == 0 {
				return vm.ToValue("")
			}
			return vm.ToValue(util.Render(list[0].node))
		}
		if len(list) == 0 {
			return vm.ToValue("")
		}
		return vm.ToValue(util.NodeAttr(list[0].node, name))
	})
	obj.Set("size", func(goja.FunctionCall) goja.Value { return vm.ToValue(len(list)) })
	// select / selectFirst：jsoup Elements 上的同名方法，把每个元素的匹配结果合并
	obj.Set("select", func(call goja.FunctionCall) goja.Value {
		css := fmt.Sprint(exportValue(call.Argument(0)))
		var nodes []*html.Node
		seen := map[*html.Node]bool{}
		for _, e := range list {
			for _, n := range util.Select(e.node, css) {
				if !seen[n] {
					seen[n] = true
					nodes = append(nodes, n)
				}
			}
		}
		return toJSValue(vm, WrapNodes(nodes))
	})
	obj.Set("selectFirst", func(call goja.FunctionCall) goja.Value {
		css := fmt.Sprint(exportValue(call.Argument(0)))
		for _, e := range list {
			if ns := util.Select(e.node, css); len(ns) > 0 {
				return toJSValue(vm, &ElementWrap{ns[0]})
			}
		}
		return goja.Null()
	})
	obj.Set("get", func(call goja.FunctionCall) goja.Value {
		i := toInt(exportValue(call.Argument(0)))
		if i < 0 || i >= len(list) {
			return goja.Null()
		}
		return list[i].Object(vm)
	})
	obj.Set("first", func(goja.FunctionCall) goja.Value {
		if len(list) == 0 {
			return goja.Null()
		}
		return list[0].Object(vm)
	})
	obj.Set("last", func(goja.FunctionCall) goja.Value {
		if len(list) == 0 {
			return goja.Null()
		}
		return list[len(list)-1].Object(vm)
	})
	obj.Set("html", func(goja.FunctionCall) goja.Value {
		if len(list) == 0 {
			return vm.ToValue("")
		}
		return vm.ToValue(util.Render(list[0].node))
	})
	obj.Set("outerHtml", func(goja.FunctionCall) goja.Value {
		var sb strings.Builder
		for _, e := range list {
			sb.WriteString(util.Render(e.node))
		}
		return vm.ToValue(sb.String())
	})
	obj.Set("toString", func(goja.FunctionCall) goja.Value {
		var sb strings.Builder
		for _, e := range list {
			sb.WriteString(util.Render(e.node))
		}
		return vm.ToValue(sb.String())
	})
	return obj
}

// —— org.* 静态类（模拟 Rhino 里的 Java 类访问） ——

// newOrgObject 提供书源 JS 常用的 `org.*` 静态方法。
//
// legado 的 JS 跑在 Rhino 上，脚本能直接引用 Java 类；书源因此大量使用
// `org.jsoup.Jsoup.parse(java.ajax(url))` 把接口/页面字符串变成可 select 的文档。
// Go 侧没有 Java，必须显式造出同名对象——否则脚本一开始就抛
// "org is not defined"，整个发现分类/规则链拿不到任何结果，且往往只表现为空列表。
func newOrgObject(vm *goja.Runtime) *goja.Object {
	org := vm.NewObject()
	jsoup := vm.NewObject()

	parse := func(call goja.FunctionCall) goja.Value {
		raw := fmt.Sprint(exportValue(call.Argument(0)))
		if strings.TrimSpace(raw) == "" {
			return goja.Null()
		}
		doc, err := util.ParseHTML(raw)
		if err != nil {
			return goja.Null()
		}
		return toJSValue(vm, &ElementWrap{doc})
	}

	// org.jsoup.Jsoup.parse —— 包名 / 库名 / 类名三层，书源就是这么写的。
	class := vm.NewObject()
	class.Set("parse", parse)
	// parseBodyFragment 是同一用途的别名写法。
	class.Set("parseBodyFragment", parse)
	jsoup.Set("Jsoup", class)
	// 少数脚本写成 org.jsoup.parse（省掉类名），一并兼容。
	jsoup.Set("parse", parse)
	org.Set("jsoup", jsoup)
	return org
}

// —— java 扩展对象 ——

func newJavaObject(vm *goja.Runtime, b *Bindings) *goja.Object {
	o := vm.NewObject()
	src := b.Source

	set := func(name string, fn func(call goja.FunctionCall) goja.Value) { o.Set(name, fn) }

	// ---------- 网络 ----------
	set("ajax", func(call goja.FunctionCall) goja.Value {
		u := argURL(call, 0)
		if Hooks.Ajax != nil {
			return vm.ToValue(Hooks.Ajax(src, u))
		}
		return vm.ToValue(simpleGet(src, u, nil))
	})
	set("ajaxAll", func(call goja.FunctionCall) goja.Value {
		var urls []string
		switch t := exportValue(call.Argument(0)).(type) {
		case []any:
			for _, x := range t {
				urls = append(urls, fmt.Sprint(x))
			}
		case []string:
			urls = t
		}
		// legado 返回 Array<StrResponse>，书源里常见 `.map(it => it.body)`，
		// 因此这里必须给出带 url/body/code 的对象，不能是裸字符串数组。
		out := make([]any, 0, len(urls))
		var results []*ConnectResult
		if Hooks.AjaxAll != nil {
			results = Hooks.AjaxAll(src, urls)
		} else {
			results = make([]*ConnectResult, 0, len(urls))
			for _, u := range urls {
				results = append(results, &ConnectResult{URL: u, Body: simpleGet(src, u, nil)})
			}
		}
		for _, r := range results {
			if r == nil {
				out = append(out, goja.Null())
				continue
			}
			obj := vm.NewObject()
			obj.Set("url", vm.ToValue(r.URL))
			obj.Set("body", vm.ToValue(r.Body))
			obj.Set("code", vm.ToValue(r.Code))
			out = append(out, obj)
		}
		return vm.ToValue(out)
	})
	set("connect", func(call goja.FunctionCall) goja.Value {
		u := argURL(call, 0)
		var headers map[string]string
		if len(call.Arguments) > 1 {
			switch t := exportValue(call.Argument(1)).(type) {
			case map[string]any:
				headers = map[string]string{}
				for k, v := range t {
					headers[k] = fmt.Sprint(v)
				}
			case map[string]string:
				headers = t
			case string:
				_ = t
			}
		}
		if Hooks.Connect != nil {
			r := Hooks.Connect(src, u, headers)
			if r == nil {
				return goja.Null()
			}
			obj := vm.NewObject()
			obj.Set("url", vm.ToValue(r.URL))
			obj.Set("body", vm.ToValue(r.Body))
			obj.Set("code", vm.ToValue(r.Code))
			return obj
		}
		obj := vm.NewObject()
		obj.Set("url", vm.ToValue(u))
		obj.Set("body", vm.ToValue(simpleGet(src, u, headers)))
		return obj
	})
	// java.get 有两个重载：1 参取变量、2 参发 HTTP GET（对齐 legado）。
	// goja 的对象属性只能有一个实现，所以按参数个数分派。
	// 早期分开注册两次，后注册的取变量版本把 HTTP 版本覆盖掉了，
	// `java.get(url, headers)` 恒返回空。
	set("get", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) > 1 {
			return vm.ToValue(simpleGet(src, argURL(call, 0), argHeaders(call, 1)))
		}
		k := fmt.Sprint(exportValue(call.Argument(0)))
		if b.Vars != nil {
			return vm.ToValue(b.Vars.Get(k))
		}
		return vm.ToValue("")
	})
	set("post", func(call goja.FunctionCall) goja.Value {
		u := argURL(call, 0)
		body := ""
		if len(call.Arguments) > 1 {
			body = fmt.Sprint(exportValue(call.Argument(1)))
		}
		headers := argHeaders(call, 2)
		r, err := net.Default().Do(net.Options{
			URL: u, Method: "POST", Headers: headers, Body: body,
			SaveCookie: src == nil || src.EnabledCookieJarOn(),
		})
		if err != nil || r == nil {
			return vm.ToValue("")
		}
		return vm.ToValue(r.Body)
	})
	set("head", func(call goja.FunctionCall) goja.Value {
		r, err := net.Default().Do(net.Options{URL: argURL(call, 0), Method: "HEAD", Headers: argHeaders(call, 1)})
		if err != nil || r == nil {
			return goja.Null()
		}
		obj := vm.NewObject()
		obj.Set("code", vm.ToValue(r.StatusCode))
		for k, v := range r.Headers {
			obj.Set(k, vm.ToValue(v))
		}
		return obj
	})
	// ---------- 变量 ----------
	set("put", func(call goja.FunctionCall) goja.Value {
		k := fmt.Sprint(exportValue(call.Argument(0)))
		v := fmt.Sprint(exportValue(call.Argument(1)))
		if b.Vars != nil {
			v = b.Vars.Put(k, v)
		}
		return vm.ToValue(v)
	})
	set("getString", func(call goja.FunctionCall) goja.Value {
		k := fmt.Sprint(exportValue(call.Argument(0)))
		if b.Vars != nil {
			return vm.ToValue(b.Vars.Get(k))
		}
		return vm.ToValue("")
	})
	set("putVar", func(call goja.FunctionCall) goja.Value {
		k := fmt.Sprint(exportValue(call.Argument(0)))
		v := fmt.Sprint(exportValue(call.Argument(1)))
		if b.Vars != nil {
			b.Vars.Put(k, v)
		}
		return vm.ToValue(v)
	})
	set("getVar", func(call goja.FunctionCall) goja.Value {
		k := fmt.Sprint(exportValue(call.Argument(0)))
		if b.Vars != nil {
			return vm.ToValue(b.Vars.Get(k))
		}
		return vm.ToValue("")
	})
	// ---------- 编码 ----------
	set("base64Decode", func(call goja.FunctionCall) goja.Value {
		s := fmt.Sprint(exportValue(call.Argument(0)))
		flags := 0
		if len(call.Arguments) > 1 {
			flags = toInt(exportValue(call.Argument(1)))
		}
		if strings.EqualFold(s, "") {
			return vm.ToValue("")
		}
		if flags == 0 && s == "" {
			return vm.ToValue("")
		}
		return vm.ToValue(util.Base64Decode(s, flags))
	})
	// base64DecodeToByteArray —— 返回字节数组而不是字符串。
	//
	// 漫画源常用它解码页面里的加密负载（AES 的 key/iv 也是这么来的）：
	// 先 base64 解出「16 字节 IV + 密文」，再喂给 createSymmetricCrypto。
	set("base64DecodeToByteArray", func(call goja.FunctionCall) goja.Value {
		// 页面里的 base64 常被 JS 转义（`\/`、`\u002b`），先还原再解码。
		s := strings.TrimSpace(util.UnescapeJSString(fmt.Sprint(exportValue(call.Argument(0)))))
		if s == "" {
			// 对齐原版：空入参返回 null，而不是空数组，避免脚本误判长度。
			return goja.Null()
		}
		flags := 0
		if len(call.Arguments) > 1 {
			flags = toInt(exportValue(call.Argument(1)))
		}
		var data []byte
		if flags == 1 {
			data, _ = base64.URLEncoding.DecodeString(s)
		} else {
			data = util.Base64DecodeBytes(s)
		}
		return toJSBytes(vm, data)
	})
	set("base64Encode", func(call goja.FunctionCall) goja.Value {
		s := fmt.Sprint(exportValue(call.Argument(0)))
		flags := 2
		if len(call.Arguments) > 1 {
			flags = toInt(exportValue(call.Argument(1)))
		}
		return vm.ToValue(util.Base64Encode(s, flags))
	})
	set("md5Encode", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(Md5(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	set("md5Encode16", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(Md5(fmt.Sprint(exportValue(call.Argument(0))))[8:24])
	})
	set("hexEncodeToString", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(util.HexEncode(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	set("hexDecodeToString", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(util.HexDecodeString(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	set("hexDecodeToByteArray", func(call goja.FunctionCall) goja.Value {
		s := strings.TrimSpace(util.UnescapeJSString(fmt.Sprint(exportValue(call.Argument(0)))))
		if s == "" {
			return goja.Null()
		}
		return toJSBytes(vm, util.HexDecode(s))
	})
	set("strToBytes", func(call goja.FunctionCall) goja.Value {
		// 统一用数字数组（= Java byte[]），脚本里的 buf.length / buf[i] 才成立。
		return toJSBytes(vm, []byte(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	set("bytesToStr", func(call goja.FunctionCall) goja.Value {
		data := bytesArg(call, 0)
		// 第二个参数是编码名，如 java.bytesToStr(buf, 'UTF-8')。
		charset := "UTF-8"
		if len(call.Arguments) > 1 {
			if s := strings.TrimSpace(fmt.Sprint(exportValue(call.Argument(1)))); s != "" {
				charset = s
			}
		}
		if len(data) == 0 {
			// 入参本来就是字符串时要原样返回，不能因为解不出字节就变空串。
			if s, ok := exportValue(call.Argument(0)).(string); ok {
				return vm.ToValue(s)
			}
			return vm.ToValue("")
		}
		return vm.ToValue(util.DecodeBytes(data, charset))
	})
	// createSymmetricCrypto —— 漫画源用来解章节图片清单（AES/DES 系）。
	//
	// 签名对齐 Hutool：createSymmetricCrypto(transformation, key, iv?)，
	// key / iv 既可以是字节数组，也可以是字符串（按 UTF-8 取字节）。
	set("createSymmetricCrypto", func(call goja.FunctionCall) goja.Value {
		trans := strings.TrimSpace(fmt.Sprint(exportValue(call.Argument(0))))
		key := cryptoBytes(call.Argument(1))
		var iv []byte
		if len(call.Arguments) > 2 {
			iv = cryptoBytes(call.Argument(2))
		}
		c, err := newSymmetricCrypto(trans, key, iv)
		if err != nil {
			panic(vm.NewGoError(fmt.Errorf("createSymmetricCrypto: %w", err)))
		}
		return c.toJSObject(vm)
	})
	set("encodeURI", func(call goja.FunctionCall) goja.Value {
		s := fmt.Sprint(exportValue(call.Argument(0)))
		return vm.ToValue(url.QueryEscape(s))
	})
	set("decodeURI", func(call goja.FunctionCall) goja.Value {
		s := fmt.Sprint(exportValue(call.Argument(0)))
		v, _ := url.QueryUnescape(s)
		return vm.ToValue(v)
	})
	// 对齐 legado JsExtensions: java.htmlFormat 用的是 formatKeepImg
	set("htmlFormat", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(util.FormatKeepImg(fmt.Sprint(exportValue(call.Argument(0))), ""))
	})
	// java.util.Arrays：不少源写 Packages.java.util.Arrays，也有直接写 java.util.Arrays 的，
	// 两条路径都指向同一份实现。
	jutil := vm.NewObject()
	jutil.Set("Arrays", newJavaArraysClass(vm))
	o.Set("util", jutil)

	// ---------- 简繁（无第三方库时原样返回）----------
	set("t2s", func(call goja.FunctionCall) goja.Value { return call.Argument(0) })
	set("s2t", func(call goja.FunctionCall) goja.Value { return call.Argument(0) })
	// ---------- 字符串工具 ----------
	set("substring", func(call goja.FunctionCall) goja.Value {
		s := fmt.Sprint(exportValue(call.Argument(0)))
		a := toInt(exportValue(call.Argument(1)))
		if len(call.Arguments) > 2 {
			bEnd := toInt(exportValue(call.Argument(2)))
			if a < 0 {
				a = 0
			}
			if bEnd > len(s) {
				bEnd = len(s)
			}
			if bEnd < a {
				bEnd = a
			}
			return vm.ToValue(s[a:bEnd])
		}
		if a < 0 {
			a = 0
		}
		if a > len(s) {
			a = len(s)
		}
		return vm.ToValue(s[a:])
	})
	set("replace", func(call goja.FunctionCall) goja.Value {
		s := fmt.Sprint(exportValue(call.Argument(0)))
		old := fmt.Sprint(exportValue(call.Argument(1)))
		nw := fmt.Sprint(exportValue(call.Argument(2)))
		return vm.ToValue(strings.ReplaceAll(s, old, nw))
	})
	set("split", func(call goja.FunctionCall) goja.Value {
		s := fmt.Sprint(exportValue(call.Argument(0)))
		sep := fmt.Sprint(exportValue(call.Argument(1)))
		parts := strings.Split(s, sep)
		arr := make([]any, 0, len(parts))
		for _, p := range parts {
			arr = append(arr, p)
		}
		return vm.ToValue(arr)
	})
	set("trim", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(strings.TrimSpace(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	// ---------- 时间 ----------
	set("timeFormat", func(call goja.FunctionCall) goja.Value {
		ms := toInt64(exportValue(call.Argument(0)))
		if ms > 1e12 {
			ms /= 1000
		}
		return vm.ToValue(time.Unix(ms, 0).Format("2006-01-02 15:04:05"))
	})
	set("timeFormatUTC", func(call goja.FunctionCall) goja.Value {
		ms := toInt64(exportValue(call.Argument(0)))
		fmtStr := "yyyy-MM-dd HH:mm:ss"
		if len(call.Arguments) > 1 {
			fmtStr = fmt.Sprint(exportValue(call.Argument(1)))
		}
		sh := 0
		if len(call.Arguments) > 2 {
			sh = toInt(exportValue(call.Argument(2)))
		}
		return vm.ToValue(time.Unix(ms/1000, 0).UTC().Add(time.Duration(sh) * time.Hour).Format(goLayout(fmtStr)))
	})
	// ---------- Cookie ----------
	set("getCookie", func(call goja.FunctionCall) goja.Value {
		u := fmt.Sprint(exportValue(call.Argument(0)))
		if len(call.Arguments) > 1 {
			return vm.ToValue(store.Default().GetKey(u, fmt.Sprint(exportValue(call.Argument(1)))))
		}
		return vm.ToValue(store.Default().GetCookie(u))
	})
	set("setCookie", func(call goja.FunctionCall) goja.Value {
		u := fmt.Sprint(exportValue(call.Argument(0)))
		c := fmt.Sprint(exportValue(call.Argument(1)))
		store.Default().ReplaceCookie(u, c)
		return goja.Undefined()
	})
	set("removeCookie", func(call goja.FunctionCall) goja.Value {
		store.Default().RemoveCookie(fmt.Sprint(exportValue(call.Argument(0))))
		return goja.Undefined()
	})
	// ---------- 文件 ----------
	set("getFile", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(safePath(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	set("readFile", func(call goja.FunctionCall) goja.Value {
		p := safePath(fmt.Sprint(exportValue(call.Argument(0))))
		b, err := os.ReadFile(p)
		if err != nil {
			return goja.Null()
		}
		return vm.ToValue(b)
	})
	set("readTxtFile", func(call goja.FunctionCall) goja.Value {
		p := safePath(fmt.Sprint(exportValue(call.Argument(0))))
		b, err := os.ReadFile(p)
		if err != nil {
			return vm.ToValue("")
		}
		cs := "utf-8"
		if len(call.Arguments) > 1 {
			cs = fmt.Sprint(exportValue(call.Argument(1)))
		} else {
			cs = util.DetectCharset("", b)
		}
		return vm.ToValue(util.DecodeBytes(b, cs))
	})
	set("deleteFile", func(call goja.FunctionCall) goja.Value {
		p := safePath(fmt.Sprint(exportValue(call.Argument(0))))
		return vm.ToValue(os.Remove(p) == nil)
	})
	set("unzipFile", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(unarchive(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	set("unArchiveFile", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(unarchive(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	set("getZipStringContent", func(call goja.FunctionCall) goja.Value {
		u := fmt.Sprint(exportValue(call.Argument(0)))
		p := fmt.Sprint(exportValue(call.Argument(1)))
		b, err := zipEntry(readRemoteOrHex(src, u), p)
		if err != nil {
			return vm.ToValue("")
		}
		cs := util.DetectCharset("", b)
		if len(call.Arguments) > 2 {
			cs = fmt.Sprint(exportValue(call.Argument(2)))
		}
		return vm.ToValue(util.DecodeBytes(b, cs))
	})
	// downloadFile 两个重载：1 参下载 URL、2 参把 hex 内容落到缓存文件
	// （对齐 legado：2 参版本要求 URL 规则里带 type，返回相对 cache 的路径）
	set("downloadFile", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) > 1 {
			return vm.ToValue(saveHexFile(src, fmt.Sprint(exportValue(call.Argument(0))),
				fmt.Sprint(exportValue(call.Argument(1)))))
		}
		u := fmt.Sprint(exportValue(call.Argument(0)))
		return vm.ToValue(downloadFile(src, u))
	})
	set("getTxtInFolder", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(readTxtInFolder(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	set("cacheFile", func(call goja.FunctionCall) goja.Value {
		u := fmt.Sprint(exportValue(call.Argument(0)))
		save := int64(0)
		if len(call.Arguments) > 1 {
			save = toInt64(exportValue(call.Argument(1)))
		}
		key := Md5(u)
		c := store.DefaultCache()
		if p := c.Get(key); p != "" {
			if b, err := os.ReadFile(safePath(p)); err == nil {
				return vm.ToValue(util.DecodeBytes(b, util.DetectCharset("", b)))
			}
		}
		rel := downloadFile(src, u)
		if rel == "" {
			return vm.ToValue("")
		}
		c.Put(key, rel, save)
		if b, err := os.ReadFile(safePath(rel)); err == nil {
			return vm.ToValue(util.DecodeBytes(b, util.DetectCharset("", b)))
		}
		return vm.ToValue("")
	})
	set("importScript", func(call goja.FunctionCall) goja.Value {
		p := fmt.Sprint(exportValue(call.Argument(0)))
		if strings.HasPrefix(p, "http") {
			return vm.ToValue(simpleGet(src, p, nil))
		}
		b, err := os.ReadFile(safePath(p))
		if err != nil {
			return vm.ToValue("")
		}
		return vm.ToValue(util.DecodeBytes(b, util.DetectCharset("", b)))
	})
	// ---------- 交互 / 调试 ----------
	set("log", func(call goja.FunctionCall) goja.Value {
		msg := fmt.Sprint(exportValue(call.Argument(0)))
		b.log("[js.log] " + msg)
		return vm.ToValue(msg)
	})
	set("logType", func(call goja.FunctionCall) goja.Value {
		v := exportValue(call.Argument(0))
		b.log(fmt.Sprintf("[js.logType] %T", v))
		return goja.Undefined()
	})
	set("toast", func(call goja.FunctionCall) goja.Value {
		b.log("[js.toast] " + fmt.Sprint(exportValue(call.Argument(0))))
		return goja.Undefined()
	})
	set("longToast", func(call goja.FunctionCall) goja.Value {
		b.log("[js.longToast] " + fmt.Sprint(exportValue(call.Argument(0))))
		return goja.Undefined()
	})
	set("randomUUID", func(goja.FunctionCall) goja.Value { return vm.ToValue(newUUID()) })
	set("androidId", func(goja.FunctionCall) goja.Value { return vm.ToValue("legado-go") })
	set("getWebViewUA", func(goja.FunctionCall) goja.Value { return vm.ToValue(net.DefaultUserAgent) })
	set("webView", func(call goja.FunctionCall) goja.Value {
		if Hooks.WebView != nil {
			h := fmt.Sprint(exportValue(call.Argument(0)))
			u := ""
			jsStr := ""
			if len(call.Arguments) > 1 {
				u = fmt.Sprint(exportValue(call.Argument(1)))
			}
			if len(call.Arguments) > 2 {
				jsStr = fmt.Sprint(exportValue(call.Argument(2)))
			}
			return vm.ToValue(Hooks.WebView(src, h, u, jsStr))
		}
		b.log("[js.webView] 本环境不支持 WebView，已降级")
		return vm.ToValue("")
	})
	set("startBrowser", func(call goja.FunctionCall) goja.Value {
		b.log("[js.startBrowser] " + fmt.Sprint(exportValue(call.Argument(0))))
		return goja.Undefined()
	})
	set("openUrl", func(call goja.FunctionCall) goja.Value {
		b.log("[js.openUrl] " + fmt.Sprint(exportValue(call.Argument(0))))
		return goja.Undefined()
	})
	set("getSource", func(goja.FunctionCall) goja.Value {
		if src != nil {
			return newSourceObject(vm, src)
		}
		return goja.Null()
	})
	set("toNumChapter", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(fmt.Sprint(exportValue(call.Argument(0))))
	})
	// ---------- preUpdateJs 专用 ----------
	// 对齐 AnalyzeRule.reGetBook / refreshTocUrl：只允许在 preUpdateJs 里调用。
	set("reGetBook", func(goja.FunctionCall) goja.Value {
		if err := requirePreUpdateJs(b); err != nil {
			panic(vm.ToValue(err.Error()))
		}
		if b.Book == nil || src == nil || Hooks.ReGetBook == nil {
			return goja.Undefined()
		}
		if err := Hooks.ReGetBook(src, b.Book); err != nil {
			panic(vm.ToValue("reGetBook 失败: " + err.Error()))
		}
		return goja.Undefined()
	})
	set("refreshTocUrl", func(goja.FunctionCall) goja.Value {
		if err := requirePreUpdateJs(b); err != nil {
			panic(vm.ToValue(err.Error()))
		}
		if b.Book == nil || src == nil || Hooks.RefreshTocUrl == nil {
			return goja.Undefined()
		}
		if err := Hooks.RefreshTocUrl(src, b.Book); err != nil {
			panic(vm.ToValue("refreshTocUrl 失败: " + err.Error()))
		}
		return goja.Undefined()
	})
	return o
}

// requirePreUpdateJs 校验调用阶段（对齐 Kotlin 的 `if (!preUpdateJs) throw`）
func requirePreUpdateJs(b *Bindings) error {
	if b == nil || !b.InPreUpdateJs {
		return fmt.Errorf("只能在 preUpdateJs 中调用")
	}
	return nil
}

// —— cookie / cache / source / book / chapter 对象 ——

func newCookieObject(vm *goja.Runtime) *goja.Object {
	o := vm.NewObject()
	o.Set("get", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(store.Default().GetCookie(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	o.Set("getCookie", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(store.Default().GetCookie(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	o.Set("getKey", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(store.Default().GetKey(fmt.Sprint(exportValue(call.Argument(0))), fmt.Sprint(exportValue(call.Argument(1)))))
	})
	o.Set("set", func(call goja.FunctionCall) goja.Value {
		store.Default().ReplaceCookie(fmt.Sprint(exportValue(call.Argument(0))), fmt.Sprint(exportValue(call.Argument(1))))
		return goja.Undefined()
	})
	o.Set("setCookie", func(call goja.FunctionCall) goja.Value {
		store.Default().SetCookie(fmt.Sprint(exportValue(call.Argument(0))), fmt.Sprint(exportValue(call.Argument(1))))
		return goja.Undefined()
	})
	o.Set("replaceCookie", func(call goja.FunctionCall) goja.Value {
		store.Default().ReplaceCookie(fmt.Sprint(exportValue(call.Argument(0))), fmt.Sprint(exportValue(call.Argument(1))))
		return goja.Undefined()
	})
	o.Set("remove", func(call goja.FunctionCall) goja.Value {
		store.Default().RemoveCookie(fmt.Sprint(exportValue(call.Argument(0))))
		return goja.Undefined()
	})
	return o
}

func newCacheObject(vm *goja.Runtime) *goja.Object {
	o := vm.NewObject()
	o.Set("get", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(store.DefaultCache().Get(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	o.Set("getString", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(store.DefaultCache().Get(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	o.Set("put", func(call goja.FunctionCall) goja.Value {
		k := fmt.Sprint(exportValue(call.Argument(0)))
		v := fmt.Sprint(exportValue(call.Argument(1)))
		ttl := int64(0)
		if len(call.Arguments) > 2 {
			ttl = toInt64(exportValue(call.Argument(2)))
		}
		store.DefaultCache().Put(k, v, ttl)
		return vm.ToValue(v)
	})
	o.Set("delete", func(call goja.FunctionCall) goja.Value {
		store.DefaultCache().Delete(fmt.Sprint(exportValue(call.Argument(0))))
		return goja.Undefined()
	})
	return o
}

func newSourceObject(vm *goja.Runtime, s *model.BookSource) *goja.Object {
	return newSourceObjectWith(vm, s, nil)
}

// newSourceObjectWith 构造 JS 里的 source 对象。
//
// b 用于取登录信息（getLoginInfoMap）与登录头落盘（putLoginHeader）：
// 这两个是登录脚本专用能力，普通规则求值时 b 里没有回调，调用会拿到空值。
func newSourceObjectWith(vm *goja.Runtime, s *model.BookSource, b *Bindings) *goja.Object {
	o := vm.NewObject()
	o.Set("bookSourceUrl", vm.ToValue(s.BookSourceUrl))
	o.Set("bookSourceName", vm.ToValue(s.BookSourceName))
	o.Set("bookSourceType", vm.ToValue(s.BookSourceType))
	o.Set("bookSourceGroup", vm.ToValue(s.BookSourceGroup))
	o.Set("bookUrlPattern", vm.ToValue(s.BookUrlPattern))
	o.Set("header", vm.ToValue(s.Header))
	o.Set("loginUrl", vm.ToValue(s.LoginUrl))
	o.Set("searchUrl", vm.ToValue(s.SearchUrl))
	o.Set("exploreUrl", vm.ToValue(s.ExploreUrl))
	o.Set("getUrl", vm.ToValue(s.BookSourceUrl))
	o.Set("getKey", func(goja.FunctionCall) goja.Value { return vm.ToValue(s.GetKey()) })
	o.Set("getTag", func(goja.FunctionCall) goja.Value { return vm.ToValue(s.GetTag()) })
	o.Set("get", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(s.Get(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	o.Set("put", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(s.Put(fmt.Sprint(exportValue(call.Argument(0))), fmt.Sprint(exportValue(call.Argument(1)))))
	})
	o.Set("getVariable", func(goja.FunctionCall) goja.Value { return vm.ToValue(s.GetVariable()) })
	o.Set("setVariable", func(call goja.FunctionCall) goja.Value {
		s.SetVariable(fmt.Sprint(exportValue(call.Argument(0))))
		return goja.Undefined()
	})
	// getLoginInfoMap：登录框里用户填的账号密码（键名就是 loginUi 里的 name）。
	// 原版这里直接暴露 Kotlin 对象的方法，书源脚本按 `source.getLoginInfoMap().账号` 取值。
	o.Set("getLoginInfoMap", func(goja.FunctionCall) goja.Value {
		out := vm.NewObject()
		if b != nil && b.LoginInfo != nil {
			for k, v := range b.LoginInfo() {
				out.Set(k, vm.ToValue(v))
			}
		}
		return out
	})
	// putLoginHeader：登录成功后保存整段请求头（含 Cookie），下次请求自动带上。
	o.Set("putLoginHeader", func(call goja.FunctionCall) goja.Value {
		if b == nil || b.SetLoginHeader == nil {
			return vm.ToValue(false)
		}
		err := b.SetLoginHeader(fmt.Sprint(exportValue(call.Argument(0))))
		return vm.ToValue(err == nil)
	})
	o.Set("toString", func(goja.FunctionCall) goja.Value { return vm.ToValue(s.BookSourceUrl) })
	return o
}

func newBookObject(vm *goja.Runtime, b *model.Book) *goja.Object {
	o := vm.NewObject()
	o.Set("name", vm.ToValue(b.Name))
	o.Set("author", vm.ToValue(b.Author))
	o.Set("bookUrl", vm.ToValue(b.BookUrl))
	o.Set("tocUrl", vm.ToValue(b.TocUrl))
	o.Set("origin", vm.ToValue(b.Origin))
	o.Set("originName", vm.ToValue(b.OriginName))
	o.Set("kind", vm.ToValue(b.Kind))
	o.Set("wordCount", vm.ToValue(b.WordCount))
	o.Set("intro", vm.ToValue(b.Intro))
	o.Set("coverUrl", vm.ToValue(b.CoverUrl))
	o.Set("type", vm.ToValue(b.Type))
	o.Set("get", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(b.GetVariable(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	o.Set("put", func(call goja.FunctionCall) goja.Value {
		k := fmt.Sprint(exportValue(call.Argument(0)))
		v := fmt.Sprint(exportValue(call.Argument(1)))
		b.PutVariable(k, v)
		return vm.ToValue(v)
	})
	o.Set("getVariable", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(b.GetVariable(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	o.Set("putVariable", func(call goja.FunctionCall) goja.Value {
		b.PutVariable(fmt.Sprint(exportValue(call.Argument(0))), fmt.Sprint(exportValue(call.Argument(1))))
		return goja.Undefined()
	})
	o.Set("toString", func(goja.FunctionCall) goja.Value { return vm.ToValue(b.BookUrl) })
	return o
}

func newChapterObject(vm *goja.Runtime, c *model.BookChapter) *goja.Object {
	o := vm.NewObject()
	o.Set("title", vm.ToValue(c.Title))
	o.Set("url", vm.ToValue(c.Url))
	o.Set("index", vm.ToValue(c.Index))
	o.Set("bookUrl", vm.ToValue(c.BookUrl))
	o.Set("tag", vm.ToValue(c.Tag))
	o.Set("isVolume", vm.ToValue(c.IsVolume))
	o.Set("isVip", vm.ToValue(c.IsVip))
	o.Set("isPay", vm.ToValue(c.IsPay))
	o.Set("get", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(c.GetVariable(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	o.Set("put", func(call goja.FunctionCall) goja.Value {
		k := fmt.Sprint(exportValue(call.Argument(0)))
		v := fmt.Sprint(exportValue(call.Argument(1)))
		c.PutVariable(k, v)
		return vm.ToValue(v)
	})
	o.Set("toString", func(goja.FunctionCall) goja.Value { return vm.ToValue(c.Url) })
	return o
}

// —— 辅助 ——

func argURL(call goja.FunctionCall, i int) string {
	v := exportValue(call.Argument(i))
	switch t := v.(type) {
	case []any:
		if len(t) > 0 {
			return fmt.Sprint(t[0])
		}
		return ""
	case []string:
		if len(t) > 0 {
			return t[0]
		}
		return ""
	}
	return fmt.Sprint(v)
}

func argHeaders(call goja.FunctionCall, i int) map[string]string {
	if len(call.Arguments) <= i {
		return nil
	}
	switch t := exportValue(call.Argument(i)).(type) {
	case map[string]any:
		m := map[string]string{}
		for k, v := range t {
			m[k] = fmt.Sprint(v)
		}
		return m
	case map[string]string:
		return t
	}
	return nil
}

func toInt(v any) int {
	switch t := v.(type) {
	case int:
		return t
	case int64:
		return int(t)
	case float64:
		return int(t)
	case string:
		var n int
		_, _ = fmt.Sscanf(t, "%d", &n)
		return n
	}
	return 0
}

func toInt64(v any) int64 {
	switch t := v.(type) {
	case int:
		return int64(t)
	case int64:
		return t
	case float64:
		return int64(t)
	}
	return 0
}

func simpleGet(src *model.BookSource, u string, headers map[string]string) string {
	r, err := net.Default().Do(net.Options{
		URL:        u,
		Method:     "GET",
		Headers:    headers,
		SaveCookie: src == nil || src.EnabledCookieJarOn(),
	})
	if err != nil || r == nil {
		return ""
	}
	return r.Body
}

func downloadFile(src *model.BookSource, u string) string {
	r, err := net.Default().Do(net.Options{
		URL:        u,
		Method:     "GET",
		SaveCookie: src == nil || src.EnabledCookieJarOn(),
	})
	if err != nil || r == nil {
		return ""
	}
	suffix := util.GetSuffix(u)
	if suffix == "" {
		suffix = "bin"
	}
	_ = os.MkdirAll(FileRoot, 0o755)
	name := Md5(u) + "." + suffix
	if err := os.WriteFile(filepath.Join(FileRoot, name), r.Bytes, 0o644); err != nil {
		return ""
	}
	return name
}

// saveHexFile 对齐 legado 的 downloadFile(content, url)：把 hex 内容写到
// `<md5(url)>.<type>`，返回相对 cache 的路径；URL 规则没有 type 时返回空。
func saveHexFile(src *model.BookSource, content, u string) string {
	if Hooks.URLType == nil {
		return ""
	}
	typ := Hooks.URLType(src, u)
	if typ == "" {
		return ""
	}
	raw, err := hex.DecodeString(strings.TrimSpace(content))
	if err != nil && len(raw) == 0 {
		return ""
	}
	_ = os.MkdirAll(FileRoot, 0o755)
	name := Md5(u) + "." + typ
	if err := os.WriteFile(filepath.Join(FileRoot, name), raw, 0o644); err != nil {
		return ""
	}
	return "/" + name
}

// readTxtInFolder 对齐 legado 的 getTxtInFolder：把目录下所有文件按各自编码
// 读出并以换行拼接，读完删除该目录。
func readTxtInFolder(p string) string {
	if strings.TrimSpace(p) == "" {
		return ""
	}
	dir := safePath(p)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	var sb strings.Builder
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		sb.WriteString(util.DecodeBytes(b, util.DetectCharset("", b)))
		sb.WriteString("\n")
	}
	// 与 Kotlin 一致：读完即清理，避免下次重复拼入旧内容
	_ = os.RemoveAll(dir)
	return strings.TrimSuffix(sb.String(), "\n")
}

func safePath(p string) string {
	root, _ := filepath.Abs(FileRoot)
	target := p
	if !filepath.IsAbs(target) {
		target = filepath.Join(root, target)
	}
	abs, _ := filepath.Abs(target)
	if !strings.HasPrefix(abs, root) {
		return filepath.Join(root, "invalid")
	}
	return abs
}

func unarchive(zipPath string) string {
	// 简化实现：仅解 zip，返回解包后的相对目录名
	p := safePath(zipPath)
	r, err := zip.OpenReader(p)
	if err != nil {
		return ""
	}
	defer r.Close()
	outDir := Md5(filepath.Base(p))
	dest := filepath.Join(FileRoot, outDir)
	_ = os.MkdirAll(dest, 0o755)
	for _, f := range r.File {
		fp := filepath.Join(dest, f.Name)
		if !strings.HasPrefix(fp, dest) {
			continue
		}
		if f.FileInfo().IsDir() {
			_ = os.MkdirAll(fp, 0o755)
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue
		}
		var buf bytes.Buffer
		_, _ = buf.ReadFrom(rc)
		_ = rc.Close()
		_ = os.MkdirAll(filepath.Dir(fp), 0o755)
		_ = os.WriteFile(fp, buf.Bytes(), 0o644)
	}
	return outDir
}

func readRemoteOrHex(src *model.BookSource, u string) []byte {
	if util.IsAbsUrl(u) {
		r, _ := net.Default().Do(net.Options{URL: u, Method: "GET", SaveCookie: src == nil || src.EnabledCookieJarOn()})
		if r != nil {
			return r.Bytes
		}
		return nil
	}
	return util.HexDecode(u)
}

func zipEntry(data []byte, name string) ([]byte, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("empty")
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, err
	}
	for _, f := range zr.File {
		if f.Name == name {
			rc, err := f.Open()
			if err != nil {
				return nil, err
			}
			var buf bytes.Buffer
			_, _ = buf.ReadFrom(rc)
			_ = rc.Close()
			return buf.Bytes(), nil
		}
	}
	return nil, fmt.Errorf("not found")
}

func goLayout(f string) string {
	r := strings.NewReplacer(
		"yyyy", "2006", "MM", "01", "dd", "02",
		"HH", "15", "mm", "04", "ss", "05",
	)
	return r.Replace(f)
}

func newUUID() string {
	return fmt.Sprintf("%x-%x-%x", time.Now().UnixNano(), os.Getpid(), md5.Sum([]byte(fmt.Sprint(time.Now().UnixNano()))))
}
