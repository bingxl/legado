package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
)

// ReaderAPI 暴露阅读器所需的目录与正文能力。
type ReaderAPI struct {
	svc readerService
}

// readerService 是阅读服务的能力契约。
type readerService interface {
	GetChapters(ctx context.Context, bookID int64) ([]dto.ChapterItem, error)
	GetContent(ctx context.Context, bookID int64, index int) (dto.ChapterContent, error)
	SaveProgress(ctx context.Context, bookID int64, chapterIndex int, chapterTitle string, chapterPos int, scrollPercent float64) error
	GetProgress(ctx context.Context, bookID int64) (dto.ReadingPosition, error)
	SyncOutline(ctx context.Context, bookID int64, items []dto.ChapterItem) error
}

// NewReaderAPI 创建阅读绑定服务。
func NewReaderAPI(svc readerService) *ReaderAPI {
	return &ReaderAPI{svc: svc}
}

// GetChapters 获取书籍目录。
func (a *ReaderAPI) GetChapters(bookID int64) ([]dto.ChapterItem, error) {
	if bookID == 0 {
		return nil, errBadRequest("缺少书籍 ID")
	}
	return a.svc.GetChapters(newCtx(), bookID)
}

// GetContent 获取指定章节正文。
func (a *ReaderAPI) GetContent(bookID int64, index int) (dto.ChapterContent, error) {
	if bookID == 0 {
		return dto.ChapterContent{}, errBadRequest("缺少书籍 ID")
	}
	if index < 0 {
		return dto.ChapterContent{}, errBadRequest("章节序号不能为负")
	}
	return a.svc.GetContent(newCtx(), bookID, index)
}

// SaveProgress 保存阅读进度。
func (a *ReaderAPI) SaveProgress(bookID int64, chapterIndex int, chapterTitle string, chapterPos int, scrollPercent float64) error {
	if bookID == 0 {
		return errBadRequest("缺少书籍 ID")
	}
	return a.svc.SaveProgress(newCtx(), bookID, chapterIndex, chapterTitle, chapterPos, scrollPercent)
}

// SyncOutline 回写目录。
//
// PDF 的大纲由前端 pdf.js 解析后回传（浏览器的 PDF 支持远强于 Go 库），
// 后端只负责持久化。
func (a *ReaderAPI) SyncOutline(bookID int64, items []dto.ChapterItem) error {
	if bookID == 0 {
		return errBadRequest("缺少书籍 ID")
	}
	if len(items) == 0 {
		return errBadRequest("目录不能为空")
	}
	return a.svc.SyncOutline(newCtx(), bookID, items)
}

// GetProgress 读取上次阅读位置；无记录时 ChapterIndex 为 -1。
func (a *ReaderAPI) GetProgress(bookID int64) (dto.ReadingPosition, error) {
	if bookID == 0 {
		return dto.ReadingPosition{}, errBadRequest("缺少书籍 ID")
	}
	return a.svc.GetProgress(newCtx(), bookID)
}
