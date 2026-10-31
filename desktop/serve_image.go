package main

import (
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/legado/legado-go/pkg/store"
)

// imageProxyClient 用于转发章节图片请求。
//
// 单独建 client 而不是用 http.DefaultClient：默认 client 没有超时，
// 一个卡住的图片请求会把 WebView 的连接一直挂着。
var imageProxyClient = &http.Client{Timeout: 30 * time.Second}

// 浏览器默认 UA：不少图床会按 UA 拒绝非浏览器请求。
const imageProxyUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
	"(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

// serveRemoteImage 代理网络图片（漫画章节）。
//
// 为什么需要它：漫画图床普遍有防盗链，校验 Referer 是否为站点域名。
// WebView 里 <img src="https://cdn..."> 发出的 Referer 是应用自身（wails://），
// 会被直接 403（实测 manwame 的图床：无 Referer 403、带站点 Referer 200）。
// 原版 legado 也是带着书源域名去取图的，这里做同样的事：
//
//	/img/?u=<图片地址>&src=<书源地址>
//
// 只允许 http/https，避免被构造成 file:// 之类的本地读取。
func serveRemoteImage(w http.ResponseWriter, r *http.Request) {
	raw := strings.TrimSpace(r.URL.Query().Get("u"))
	if raw == "" {
		http.Error(w, "缺少参数 u", http.StatusBadRequest)
		return
	}
	target, err := url.Parse(raw)
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") {
		http.Error(w, "只支持 http/https 图片地址", http.StatusBadRequest)
		return
	}

	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, target.String(), nil)
	if err != nil {
		http.Error(w, "图片请求构造失败", http.StatusBadRequest)
		return
	}
	req.Header.Set("User-Agent", imageProxyUA)
	req.Header.Set("Accept", "image/avif,image/webp,image/*,*/*;q=0.8")
	if ref := refererFor(r.URL.Query().Get("src")); ref != "" {
		req.Header.Set("Referer", ref)
	}
	// 登录态与书源请求共用一份 CookieStore：需要登录的漫画源，图片同样要带 Cookie。
	if c := store.Default().GetCookie(target.String()); c != "" {
		req.Header.Set("Cookie", c)
	}

	resp, err := imageProxyClient.Do(req)
	if err != nil {
		http.Error(w, "图片获取失败", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close() //nolint:errcheck

	if resp.StatusCode >= 400 {
		http.Error(w, "图床返回 "+resp.Status, resp.StatusCode)
		return
	}

	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	// 图片内容按 URL 稳定，让 WebView 缓存，翻页来回时不至于重复下载。
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, _ = io.Copy(w, resp.Body)
}

// refererFor 由书源地址推出 Referer。
//
// 只要 scheme://host 一段：图床校验的是域名，带完整路径反而容易和站点规则不符。
func refererFor(src string) string {
	s := strings.TrimSpace(src)
	if s == "" {
		return ""
	}
	u, err := url.Parse(s)
	if err != nil || u.Host == "" {
		return ""
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return ""
	}
	return u.Scheme + "://" + u.Host + "/"
}
