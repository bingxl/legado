// Package port 定义应用服务层所依赖的端口（接口）。
//
// 端口的存在是为了实现依赖倒置：internal/app 只面向本包接口编程，
// 具体实现（SQLite、WebDAV、legado-go 引擎、Wails 事件）由
// internal/adapter 提供并在 main.go 注入。
//
// 由此带来的收益：业务逻辑可脱离 GUI 与数据库做单元测试。
package port

import (
	"context"

	"github.com/legado/desktop/internal/domain"
)

// BookRepository 提供书籍的持久化能力。
type BookRepository interface {
	// Create 持久化一本书并返回分配的主键。
	Create(ctx context.Context, b *domain.Book) error
	// Update 更新书籍的非零业务字段（ID 定位）。
	Update(ctx context.Context, b *domain.Book) error
	// Delete 删除书籍及其关联数据（章节、进度）。
	Delete(ctx context.Context, id int64) error
	// Get 按主键取书，不存在返回 domain.ErrNotFound。
	Get(ctx context.Context, id int64) (*domain.Book, error)
	// FindByURL 按来源标识 + 书籍 URL 定位，用于导入去重；不存在返回 domain.ErrNotFound。
	FindByURL(ctx context.Context, origin, bookURL string) (*domain.Book, error)
	// List 列出指定分组的书籍；groupID 为 0 时返回全部，按 Order、UpdatedAt 排序。
	List(ctx context.Context, groupID int64) ([]*domain.Book, error)
	// UpdateProgress 仅更新阅读进度相关字段，避免整行覆盖带来的并发写冲突。
	UpdateProgress(ctx context.Context, id int64, chapterIndex int, chapterTitle string, chapterPos int) error
}

// BookGroupRepository 提供书架分组的持久化能力。
type BookGroupRepository interface {
	Create(ctx context.Context, g *domain.BookGroup) error
	Update(ctx context.Context, g *domain.BookGroup) error
	Delete(ctx context.Context, id int64) error
	Get(ctx context.Context, id int64) (*domain.BookGroup, error)
	List(ctx context.Context) ([]*domain.BookGroup, error)
}

// ChapterRepository 提供章节列表的持久化能力。
type ChapterRepository interface {
	// ReplaceAll 以原子方式替换某本书的全部章节（先删后插，同一事务内）。
	ReplaceAll(ctx context.Context, bookID int64, chapters []*domain.BookChapter) error
	// List 返回某本书的全部章节，按 Index 升序。
	List(ctx context.Context, bookID int64) ([]*domain.BookChapter, error)
	// Get 按书 + 章节序号取章节，不存在返回 domain.ErrNotFound。
	Get(ctx context.Context, bookID int64, index int) (*domain.BookChapter, error)
	// DeleteByBook 删除某本书的全部章节。
	DeleteByBook(ctx context.Context, bookID int64) error
}

// ProgressRepository 提供阅读进度的持久化能力。
type ProgressRepository interface {
	Save(ctx context.Context, p *domain.ReadingProgress) error
	Get(ctx context.Context, bookID int64) (*domain.ReadingProgress, error)
	Delete(ctx context.Context, bookID int64) error
}

// BookSourceRepository 提供书源的持久化能力。
type BookSourceRepository interface {
	Create(ctx context.Context, s *domain.BookSource) error
	Update(ctx context.Context, s *domain.BookSource) error
	Delete(ctx context.Context, id int64) error
	Get(ctx context.Context, id int64) (*domain.BookSource, error)
	// FindByURL 按书源 URL 定位，用于导入去重；不存在返回 domain.ErrNotFound。
	FindByURL(ctx context.Context, url string) (*domain.BookSource, error)
	// List 列出书源；group 为空字符串时返回全部，按 Order、Name 排序。
	List(ctx context.Context, group string) ([]*domain.BookSource, error)
	// ListEnabled 列出全部启用书源，供搜索/发现使用。
	ListEnabled(ctx context.Context) ([]*domain.BookSource, error)
}

// ReplaceRuleRepository 提供全局替换规则的持久化能力。
type ReplaceRuleRepository interface {
	Create(ctx context.Context, r *domain.ReplaceRule) error
	Update(ctx context.Context, r *domain.ReplaceRule) error
	Delete(ctx context.Context, id int64) error
	Get(ctx context.Context, id int64) (*domain.ReplaceRule, error)
	List(ctx context.Context) ([]*domain.ReplaceRule, error)
	ListEnabled(ctx context.Context) ([]*domain.ReplaceRule, error)
}

// SubscriptionRepository 提供书源订阅的持久化能力。
type SubscriptionRepository interface {
	Create(ctx context.Context, s *domain.SourceSubscription) error
	Update(ctx context.Context, s *domain.SourceSubscription) error
	Delete(ctx context.Context, id int64) error
	Get(ctx context.Context, id int64) (*domain.SourceSubscription, error)
	List(ctx context.Context) ([]*domain.SourceSubscription, error)
}

// SourceLoginRepository 提供书源登录信息的持久化能力。
//
// 主键是书源地址（bookSourceUrl）：登录态跟着站点走，书源换个 id
// 或重新导入同一份 JSON 都不应该丢登录；换了域名则自然失效。
type SourceLoginRepository interface {
	// Get 读取登录信息，不存在时返回 domain.ErrNotFound。
	Get(ctx context.Context, sourceURL string) (domain.SourceLogin, error)
	// Save 写入或覆盖登录信息。
	Save(ctx context.Context, login domain.SourceLogin) error
	// Delete 删除登录信息；不存在不算错误（清除登录要幂等）。
	Delete(ctx context.Context, sourceURL string) error
	// ListSourceURLs 列出所有已保存登录信息的书源地址（清理孤儿记录用）。
	ListSourceURLs(ctx context.Context) ([]string, error)
}

// UnitOfWork 界定一个事务边界，使跨仓储的写入保持原子性。
//
// fn 返回 error 时整个事务回滚。
type UnitOfWork interface {
	// Do 在单个事务内执行 fn；fn 内部应通过参数传入的仓储访问数据。
	Do(ctx context.Context, fn func(ctx context.Context) error) error
}
