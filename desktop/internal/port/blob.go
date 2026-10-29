package port

import (
	"context"
	"io"
)

// BlobStore 管理二进制资源（封面、缓存图片等）的存储与访问。
//
// 抽象为接口是为了让 app 层不直接依赖本地文件系统，
// 便于测试替换，也为将来切换到内嵌 HTTP 服务或云存储留出空间。
type BlobStore interface {
	// Save 将 r 的内容保存到 category 分类下的 name，返回可供前端访问的地址。
	Save(ctx context.Context, category, name string, r io.Reader) (string, error)
	// Remove 删除指定资源。
	Remove(ctx context.Context, category, name string) error
}

// 二进制资源分类常量。
const (
	// BlobCategoryCover 书籍封面。
	BlobCategoryCover = "covers"
	// BlobCategoryCache 章节缓存的图片等临时资源。
	BlobCategoryCache = "cache"
)
