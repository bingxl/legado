// Package webdav 基于 github.com/studio-b12/gowebdav 实现 port.WebDAVClient。
//
// 选库说明：标准库的 golang.org/x/net/webdav 只提供**服务端**实现，
// 没有客户端；gowebdav 是纯 Go 的客户端实现，无 cgo 依赖。
package webdav

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	gowebdav "github.com/studio-b12/gowebdav"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// Client 实现 port.WebDAVClient。
type Client struct {
	inner *gowebdav.Client
}

// NewClient 按配置创建客户端。
func NewClient(cfg domain.WebDAVConfig) (*Client, error) {
	if cfg.URL == "" {
		return nil, fmt.Errorf("%w: 服务地址不能为空", domain.ErrNotConfigured)
	}
	c := gowebdav.NewClient(cfg.URL, cfg.Username, cfg.Password)
	c.SetTimeout(30 * time.Second)
	return &Client{inner: c}, nil
}

var _ port.WebDAVClient = (*Client)(nil)

// List 列出目录下的条目。
//
// 注意：gowebdav 的 API 不接受 context，取消语义无法透传到底层。
// 这里在发起请求前检查 ctx 状态，保证已取消的请求不会发出。
func (c *Client) List(ctx context.Context, path string) ([]port.WebDAVEntry, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	infos, err := c.inner.ReadDir(normalize(path))
	if err != nil {
		return nil, wrapRemoteErr(err)
	}
	out := make([]port.WebDAVEntry, 0, len(infos))
	for _, fi := range infos {
		out = append(out, port.WebDAVEntry{
			Path:    joinPath(path, fi.Name()),
			Name:    fi.Name(),
			IsDir:   fi.IsDir(),
			Size:    fi.Size(),
			ModTime: fi.ModTime(),
		})
	}
	return out, nil
}

// Stat 查询单个条目。
func (c *Client) Stat(ctx context.Context, path string) (*port.WebDAVEntry, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	fi, err := c.inner.Stat(normalize(path))
	if err != nil {
		return nil, wrapRemoteErr(err)
	}
	return &port.WebDAVEntry{
		Path:    normalize(path),
		Name:    fi.Name(),
		IsDir:   fi.IsDir(),
		Size:    fi.Size(),
		ModTime: fi.ModTime(),
	}, nil
}

// Download 读取远端文件。
func (c *Client) Download(ctx context.Context, path string) (io.ReadCloser, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	rc, err := c.inner.ReadStream(normalize(path))
	if err != nil {
		return nil, wrapRemoteErr(err)
	}
	return rc, nil
}

// Upload 写入远端文件，自动创建父目录。
func (c *Client) Upload(ctx context.Context, path string, r io.Reader) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	target := normalize(path)
	if dir := parentDir(target); dir != "" {
		if err := c.MkdirAll(ctx, dir); err != nil {
			return err
		}
	}
	if err := c.inner.WriteStream(target, r, 0o644); err != nil {
		return wrapRemoteErr(err)
	}
	return nil
}

// MkdirAll 递归创建目录。
func (c *Client) MkdirAll(ctx context.Context, path string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := c.inner.MkdirAll(normalize(path), 0o755); err != nil {
		return wrapRemoteErr(err)
	}
	return nil
}

// Delete 删除文件或目录。
func (c *Client) Delete(ctx context.Context, path string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := c.inner.Remove(normalize(path)); err != nil {
		return wrapRemoteErr(err)
	}
	return nil
}

// Factory 实现 port.WebDAVClientFactory。
type Factory struct{}

// NewFactory 创建客户端工厂。
func NewFactory() *Factory { return &Factory{} }

var _ port.WebDAVClientFactory = (*Factory)(nil)

// New 依据配置创建客户端。
func (f *Factory) New(cfg domain.WebDAVConfig) (port.WebDAVClient, error) {
	return NewClient(cfg)
}

// wrapRemoteErr 把底层错误映射为领域错误。
func wrapRemoteErr(err error) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	// gowebdav 对 404 返回 *os.PathError，这里统一映射为「不存在」。
	if os.IsNotExist(err) || strings.Contains(msg, "404") || strings.Contains(msg, "Not Found") {
		return fmt.Errorf("%w: 远端路径不存在", domain.ErrNotFound)
	}
	if strings.Contains(msg, "401") || strings.Contains(msg, "Unauthorized") || strings.Contains(msg, "403") {
		return fmt.Errorf("%w: 认证失败，请检查用户名与密码", domain.ErrRemoteFailed)
	}
	return fmt.Errorf("%w: %s", domain.ErrRemoteFailed, msg)
}

// normalize 规整远端路径：统一以 / 开头且不以 / 结尾（根目录除外）。
func normalize(p string) string {
	p = strings.TrimSpace(p)
	if p == "" {
		return "/"
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	if len(p) > 1 {
		p = strings.TrimRight(p, "/")
	}
	return p
}

// joinPath 拼接父路径与条目名。
func joinPath(parent, name string) string {
	parent = normalize(parent)
	if parent == "/" {
		return "/" + name
	}
	return parent + "/" + name
}

// parentDir 取父目录；无父目录时返回空串。
func parentDir(p string) string {
	p = normalize(p)
	i := strings.LastIndex(p, "/")
	if i <= 0 {
		return ""
	}
	return p[:i]
}
