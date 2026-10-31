package port

import (
	"context"

	"github.com/legado/desktop/internal/domain"
)

// ChapterCacheRepository 持久化已缓存的章节内容（正文或图片地址）。
//
// 只负责元数据与文本；漫画图片本体由应用层写到磁盘，仓储里存的是地址列表。
type ChapterCacheRepository interface {
	// Put 写入或覆盖一条缓存（按 书 + 章节序号 唯一）。
	Put(ctx context.Context, c *domain.CachedChapter) error
	// Get 取单章缓存；不存在返回 domain.ErrNotFound。
	Get(ctx context.Context, bookID int64, index int) (*domain.CachedChapter, error)
	// List 返回某本书的全部缓存章节，按序号升序（不含正文，正文用 Get 取）。
	List(ctx context.Context, bookID int64) ([]*domain.CachedChapter, error)
	// ListWithContent 返回某本书的全部缓存章节**含正文**，供 AI 索引一次性读入。
	//
	// 与 List 分开而不是加个开关：List 的调用方（缓存管理列表）明确不需要正文，
	// 一次读出整本书的文本会让那个页面白白多传几十 MB。
	ListWithContent(ctx context.Context, bookID int64) ([]*domain.CachedChapter, error)
	// Indexes 返回某本书已缓存的章节序号，供阅读器目录打标记。
	Indexes(ctx context.Context, bookID int64) ([]int, error)
	// BookStats 按书聚合缓存统计（章节数、总字节、更新时间）。
	BookStats(ctx context.Context) ([]domain.CacheBookStat, error)
	// Delete 删除某本书的指定章节缓存。
	Delete(ctx context.Context, bookID int64, indexes []int) error
	// DeleteByBook 删除某本书的全部缓存。
	DeleteByBook(ctx context.Context, bookID int64) error
	// DeleteAll 清空全部缓存。
	DeleteAll(ctx context.Context) error
}

// ImageDownloader 下载网络图片，供漫画章节缓存使用。
//
// 单独抽象而不是直接用 http.Get：图床普遍有防盗链，必须按书源域名带 Referer，
// 且需要按内容推断扩展名——这两件事都属于基础设施细节，不该扩散到 app 层。
type ImageDownloader interface {
	// Download 取回图片字节与扩展名（含前导点，如 ".jpg"）。
	// referer 为书源地址，用来推出 Referer 头；为空时不带 Referer。
	Download(ctx context.Context, url, referer string) ([]byte, string, error)
}
