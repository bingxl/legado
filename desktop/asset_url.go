package main

import (
	"encoding/base64"
	"net/http"
	"strings"
)

// 本地资源路由的参数编码。
//
// 为什么参数要放进路径段而不是查询串：
// 安卓宿主用 WebViewAssetLoader 拦截 https://wails.localhost 的请求，它的
// PathHandler 只把**路径**交给 Go，查询串在到达 assetHandler 之前就被丢掉了
// （Wails 自己的 MainActivity 里也为此把 /wails/ 的查询串手工拼回去）。
// 于是 "/raw/?p=..." 到后端时 p 为空 → 400 → 安卓侧再把非 200 视为「找不到资源」
// 返回 null → WebView 回落到真实网络 → 域名不存在，前端只能看到 "Failed to fetch"。
//
// 路径段用 base64url 而不是 URL 编码：绝对路径里有 "/"、"C:" 和中文，
// 直接拼进路径会被 WebView 与 http.ServeMux 改写（%2F 尤其不可靠）。
// 扩展名单独追加在末尾，因为安卓侧按路径扩展名决定 Content-Type——
// PDF 拿不到 application/pdf 就没法内嵌预览。
const (
	rawPrefix = "/raw/"
	imgPrefix = "/img/"
)

// encodeAssetArg 把任意文本编成可放进路径段的形式：base64url，不带 padding。
func encodeAssetArg(s string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(s))
}

// decodeAssetArg 取一个路径参数。
//
// 优先读路径段（安卓与桌面都走这条），读不到再回落到查询串，兼容旧链接与
// 桌面端早期写法。queryKey 只在回落时使用。
func decodeAssetArg(r *http.Request, prefix, queryKey string) (string, bool) {
	if rest, ok := strings.CutPrefix(r.URL.Path, prefix); ok && rest != "" {
		seg, _ := splitExt(rest)
		if b, err := base64.RawURLEncoding.DecodeString(seg); err == nil && len(b) > 0 {
			return string(b), true
		}
	}
	if v := strings.TrimSpace(r.URL.Query().Get(queryKey)); v != "" {
		return v, true
	}
	return "", false
}

// splitExt 拆出扩展名（含点，如 ".pdf"），没有则 ext 为空。
//
// base64url 的字符集里没有 "."，所以按最后一个点切分不会切错。
func splitExt(s string) (base, ext string) {
	i := strings.LastIndexByte(s, '.')
	if i <= 0 || len(s)-i > 9 {
		return s, ""
	}
	for _, c := range s[i+1:] {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			return s, ""
		}
	}
	return s[:i], s[i:]
}
