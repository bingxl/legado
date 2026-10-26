package js

import (
	"archive/zip"
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
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
	AjaxAll   func(src *model.BookSource, urls []string) []string
	Connect   func(src *model.BookSource, u string, headers map[string]string) *ConnectResult
	WebView   func(src *model.BookSource, htmlStr, urlStr, jsStr string) string
	GetCookie func(u string) string
	SetCookie func(u, cookie string)
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
			return vm.ToValue(util.NodeText(e.node))
		}
		return vm.ToValue(util.NodeAttr(e.node, name))
	})
	o.Set("text", func(goja.FunctionCall) goja.Value { return vm.ToValue(util.NodeText(e.node)) })
	o.Set("ownText", func(goja.FunctionCall) goja.Value { return vm.ToValue(util.NodeOwnText(e.node)) })
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
		out := make([]any, 0, len(urls))
		if Hooks.AjaxAll != nil {
			for _, r := range Hooks.AjaxAll(src, urls) {
				out = append(out, r)
			}
		} else {
			for _, u := range urls {
				out = append(out, simpleGet(src, u, nil))
			}
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
	set("get", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(simpleGet(src, argURL(call, 0), argHeaders(call, 1)))
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
	set("get", func(call goja.FunctionCall) goja.Value {
		k := fmt.Sprint(exportValue(call.Argument(0)))
		if b.Vars != nil {
			return vm.ToValue(b.Vars.Get(k))
		}
		return vm.ToValue("")
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
	set("strToBytes", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue([]byte(fmt.Sprint(exportValue(call.Argument(0)))))
	})
	set("bytesToStr", func(call goja.FunctionCall) goja.Value {
		switch t := exportValue(call.Argument(0)).(type) {
		case []byte:
			return vm.ToValue(string(t))
		case string:
			return vm.ToValue(t)
		}
		return vm.ToValue("")
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
	set("downloadFile", func(call goja.FunctionCall) goja.Value {
		u := fmt.Sprint(exportValue(call.Argument(0)))
		return vm.ToValue(downloadFile(src, u))
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
		OnLog("[js.log] " + msg)
		return vm.ToValue(msg)
	})
	set("logType", func(call goja.FunctionCall) goja.Value {
		v := exportValue(call.Argument(0))
		OnLog(fmt.Sprintf("[js.logType] %T", v))
		return goja.Undefined()
	})
	set("toast", func(call goja.FunctionCall) goja.Value {
		OnLog("[js.toast] " + fmt.Sprint(exportValue(call.Argument(0))))
		return goja.Undefined()
	})
	set("longToast", func(call goja.FunctionCall) goja.Value {
		OnLog("[js.longToast] " + fmt.Sprint(exportValue(call.Argument(0))))
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
		OnLog("[js.webView] 本环境不支持 WebView，已降级")
		return vm.ToValue("")
	})
	set("startBrowser", func(call goja.FunctionCall) goja.Value {
		OnLog("[js.startBrowser] " + fmt.Sprint(exportValue(call.Argument(0))))
		return goja.Undefined()
	})
	set("openUrl", func(call goja.FunctionCall) goja.Value {
		OnLog("[js.openUrl] " + fmt.Sprint(exportValue(call.Argument(0))))
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
	return o
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
