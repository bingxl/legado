// Package imagefetch 下载网络图片，供漫画章节缓存使用。
//
// 为什么不直接用 http.Get：漫画图床普遍校验 Referer（无 Referer 或来源不符一律 403），
// 且返回的 Content-Type 未必可靠，需要自行推断扩展名以生成正确的文件名——
// 这两点都是基础设施细节，集中在这里，app 层只看到「拿到字节与扩展名」。
package imagefetch

import (
	"context"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"

	"github.com/legado/legado-go/pkg/store"

	"github.com/legado/desktop/internal/port"
)

// Downloader 实现 port.ImageDownloader。
type Downloader struct {
	client    *http.Client
	userAgent string
	// maxBytes 是单张图片的大小上限，防止异常响应把内存吃穿。
	maxBytes int64
}

// 默认单张图片上限：32MB（足够覆盖长条漫的分片，又不会因为错误的 URL
// 指向一个视频/压缩包而耗尽内存）。
const defaultMaxBytes = 32 << 20

var _ port.ImageDownloader = (*Downloader)(nil)

// New 创建下载器。userAgent 为空时使用内置的桌面浏览器 UA。
func New(userAgent string) *Downloader {
	if strings.TrimSpace(userAgent) == "" {
		userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
			"(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	}
	return &Downloader{
		// 不设全局默认：单张图卡住会拖住整个缓存任务。
		client:    &http.Client{Timeout: 60 * time.Second},
		userAgent: userAgent,
		maxBytes:  defaultMaxBytes,
	}
}

// Download 取回图片字节与扩展名。
func (d *Downloader) Download(ctx context.Context, rawURL, referer string) ([]byte, string, error) {
	target, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") {
		return nil, "", fmt.Errorf("不支持的图片地址")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return nil, "", fmt.Errorf("构造图片请求失败: %w", err)
	}
	req.Header.Set("User-Agent", d.userAgent)
	req.Header.Set("Accept", "image/avif,image/webp,image/*,*/*;q=0.8")
	if ref := refererOf(referer); ref != "" {
		req.Header.Set("Referer", ref)
	}
	// 需要登录才能看的漫画，图床上同样要带 Cookie——书源登录后图片却 403，
	// 十次有九次是这里漏了。按域名取，登录态与书源请求共用同一份。
	if c := store.Default().GetCookie(target.String()); c != "" {
		req.Header.Set("Cookie", c)
	}

	resp, err := d.client.Do(req)
	if err != nil {
		return nil, "", fmt.Errorf("下载图片失败: %w", err)
	}
	defer resp.Body.Close() //nolint:errcheck

	if resp.StatusCode >= 400 {
		return nil, "", fmt.Errorf("图床返回 %s", resp.Status)
	}

	data, err := io.ReadAll(io.LimitReader(resp.Body, d.maxBytes+1))
	if err != nil {
		return nil, "", fmt.Errorf("读取图片失败: %w", err)
	}
	if int64(len(data)) > d.maxBytes {
		return nil, "", fmt.Errorf("图片超过 %dMB 上限", d.maxBytes>>20)
	}
	if len(data) == 0 {
		return nil, "", fmt.Errorf("图片内容为空")
	}
	return data, extOf(resp.Header.Get("Content-Type"), target.Path), nil
}

// refererOf 由书源地址推出 Referer。
//
// 只取 scheme://host：图床校验的是域名，带完整路径反而容易与站点规则不符。
func refererOf(src string) string {
	u, err := url.Parse(strings.TrimSpace(src))
	if err != nil || u.Host == "" {
		return ""
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return ""
	}
	return u.Scheme + "://" + u.Host + "/"
}

// 图片扩展名白名单：WebView 能直接渲染的那些。
var imageExts = map[string]string{
	".jpg": ".jpg", ".jpeg": ".jpg", ".png": ".png", ".gif": ".gif",
	".webp": ".webp", ".bmp": ".bmp", ".avif": ".avif", ".jxl": ".jxl",
}

// extOf 由 Content-Type 推断扩展名，失败时退回 URL 后缀，最后兜底 .jpg。
func extOf(contentType, urlPath string) string {
	if ct := strings.TrimSpace(contentType); ct != "" {
		if mt, _, err := mime.ParseMediaType(ct); err == nil {
			switch mt {
			case "image/jpeg", "image/jpg":
				return ".jpg"
			case "image/png":
				return ".png"
			case "image/gif":
				return ".gif"
			case "image/webp":
				return ".webp"
			case "image/bmp":
				return ".bmp"
			case "image/avif":
				return ".avif"
			case "image/jxl":
				return ".jxl"
			}
		}
	}
	if ext := strings.ToLower(path.Ext(urlPath)); ext != "" {
		if mapped, ok := imageExts[ext]; ok {
			return mapped
		}
	}
	return ".jpg"
}
