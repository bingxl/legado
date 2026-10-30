package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
)

// CacheAPI 暴露章节缓存的触发与管理能力。
//
// 缓存任务在后端异步执行：Start 立即返回任务快照，进度通过
// port.EventCacheProgress 推送，前端据此显示进度条与取消按钮。
type CacheAPI struct {
	svc cacheService
}

// cacheService 是缓存服务的能力契约。
type cacheService interface {
	Start(ctx context.Context, bookID int64, scope string, indexes []int) (dto.CacheJob, error)
	Cancel(bookID int64) error
	Jobs() []dto.CacheJob
	Stats(ctx context.Context) (dto.CacheStats, error)
	Books(ctx context.Context) ([]dto.CacheBookView, error)
	Chapters(ctx context.Context, bookID int64) ([]dto.CachedChapterView, error)
	Status(ctx context.Context, bookID int64) (dto.CacheBookStatus, error)
	Delete(ctx context.Context, bookID int64, indexes []int) error
	PurgeBook(ctx context.Context, bookID int64) error
	Clear(ctx context.Context) error
}

// NewCacheAPI 创建缓存绑定服务。
func NewCacheAPI(svc cacheService) *CacheAPI { return &CacheAPI{svc: svc} }

// Start 开始缓存。
//
// scope 取 all（整本）/ remaining（从当前阅读位置到结尾）/
// missing（只补缺失）/ chapters（indexes 指定的章节）。
func (a *CacheAPI) Start(bookID int64, scope string, indexes []int) (dto.CacheJob, error) {
	if bookID == 0 {
		return dto.CacheJob{}, errBadRequest("缺少书籍 ID")
	}
	return a.svc.Start(newCtx(), bookID, scope, indexes)
}

// Cancel 取消某本书正在进行的缓存。
func (a *CacheAPI) Cancel(bookID int64) error {
	if bookID == 0 {
		return errBadRequest("缺少书籍 ID")
	}
	return a.svc.Cancel(bookID)
}

// Jobs 列出全部缓存任务（含已结束的，用于展示「已完成」）。
func (a *CacheAPI) Jobs() ([]dto.CacheJob, error) {
	jobs := a.svc.Jobs()
	if jobs == nil {
		return []dto.CacheJob{}, nil
	}
	return jobs, nil
}

// Stats 返回全局缓存统计。
func (a *CacheAPI) Stats() (dto.CacheStats, error) {
	return a.svc.Stats(newCtx())
}

// Books 返回有缓存的书，用于缓存管理列表。
func (a *CacheAPI) Books() ([]dto.CacheBookView, error) {
	books, err := a.svc.Books(newCtx())
	if err != nil {
		return nil, err
	}
	if books == nil {
		return []dto.CacheBookView{}, nil
	}
	return books, nil
}

// Chapters 返回某本书已缓存的章节明细。
func (a *CacheAPI) Chapters(bookID int64) ([]dto.CachedChapterView, error) {
	if bookID == 0 {
		return nil, errBadRequest("缺少书籍 ID")
	}
	chapters, err := a.svc.Chapters(newCtx(), bookID)
	if err != nil {
		return nil, err
	}
	if chapters == nil {
		return []dto.CachedChapterView{}, nil
	}
	return chapters, nil
}

// Status 返回单本书的缓存概况（已缓存章数、占用大小、当前任务）。
func (a *CacheAPI) Status(bookID int64) (dto.CacheBookStatus, error) {
	if bookID == 0 {
		return dto.CacheBookStatus{}, errBadRequest("缺少书籍 ID")
	}
	return a.svc.Status(newCtx(), bookID)
}

// DeleteChapters 删除指定章节的缓存。
func (a *CacheAPI) DeleteChapters(bookID int64, indexes []int) error {
	if bookID == 0 {
		return errBadRequest("缺少书籍 ID")
	}
	if len(indexes) == 0 {
		return errBadRequest("未指定要删除的章节")
	}
	return a.svc.Delete(newCtx(), bookID, indexes)
}

// PurgeBook 清空某本书的全部缓存。
func (a *CacheAPI) PurgeBook(bookID int64) error {
	if bookID == 0 {
		return errBadRequest("缺少书籍 ID")
	}
	return a.svc.PurgeBook(newCtx(), bookID)
}

// Clear 清空全部缓存。
func (a *CacheAPI) Clear() error {
	return a.svc.Clear(newCtx())
}
