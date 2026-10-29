package port

import (
	"context"
	"io"
	"time"

	"github.com/legado/desktop/internal/domain"
)

// WebDAVClientFactory 按配置创建 WebDAV 客户端。
//
// 之所以用工厂而非直接注入单个客户端：连接配置可在运行时变更，
// 且未配置时不应预先建立连接。
type WebDAVClientFactory interface {
	// New 依据配置创建客户端；配置不合法时返回 domain.ErrNotConfigured。
	New(cfg domain.WebDAVConfig) (WebDAVClient, error)
}

// WebDAVEntry 描述 WebDAV 上的一个文件或目录。
type WebDAVEntry struct {
	Path    string    `json:"path"`
	Name    string    `json:"name"`
	IsDir   bool      `json:"isDir"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"modTime"`
}

// WebDAVClient 是对 WebDAV 服务的抽象，便于测试时替换为内存实现。
type WebDAVClient interface {
	// List 列出目录下的条目。
	List(ctx context.Context, path string) ([]WebDAVEntry, error)
	// Stat 查询单个条目；不存在返回 domain.ErrNotFound。
	Stat(ctx context.Context, path string) (*WebDAVEntry, error)
	// Download 读取远端文件内容，调用方负责关闭返回的 ReadCloser。
	Download(ctx context.Context, path string) (io.ReadCloser, error)
	// Upload 写入远端文件，必要时自动创建父目录。
	Upload(ctx context.Context, path string, r io.Reader) error
	// MkdirAll 递归创建目录。
	MkdirAll(ctx context.Context, path string) error
	// Delete 删除文件或目录。
	Delete(ctx context.Context, path string) error
}
