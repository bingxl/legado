package app

import (
	"context"
	"fmt"
	"strings"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ReaderService 为阅读器提供目录与正文，并负责进度落盘。
//
// 进度写入委托给 BookshelfService，避免在两个服务里重复实现同一逻辑
// （书架列表也要展示进度，两者必须写在同一处以保证一致）。
type ReaderService struct {
	content  *ContentProvider
	chapters port.ChapterRepository
	books    port.BookRepository
	shelf    *BookshelfService
	uow      port.UnitOfWork
}

// NewReaderService 构造阅读服务。
func NewReaderService(
	content *ContentProvider,
	chapters port.ChapterRepository,
	books port.BookRepository,
	shelf *BookshelfService,
	uow port.UnitOfWork,
) *ReaderService {
	return &ReaderService{content: content, chapters: chapters, books: books, shelf: shelf, uow: uow}
}

// GetChapters 返回书籍目录。
func (s *ReaderService) GetChapters(ctx context.Context, bookID int64) ([]dto.ChapterItem, error) {
	if bookID == 0 {
		return nil, fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	chapters, err := s.chapters.List(ctx, bookID)
	if err != nil {
		return nil, fmt.Errorf("读取目录失败: %w", err)
	}
	return dto.NewChapterItems(chapters), nil
}

// GetContent 取指定章节正文，并附带上下章序号以便前端预加载与翻页。
func (s *ReaderService) GetContent(ctx context.Context, bookID int64, index int) (dto.ChapterContent, error) {
	if bookID == 0 {
		return dto.ChapterContent{}, fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	if index < 0 {
		return dto.ChapterContent{}, fmt.Errorf("%w: 章节序号不能为负", domain.ErrInvalidArgument)
	}

	book, err := s.books.Get(ctx, bookID)
	if err != nil {
		return dto.ChapterContent{}, err
	}
	content, err := s.content.Chapter(ctx, bookID, index)
	if err != nil {
		return dto.ChapterContent{}, err
	}

	total := book.TotalChapters
	if total == 0 {
		// 书籍元数据缺失章节数时，以目录实际条数兜底。
		chapters, cerr := s.chapters.List(ctx, bookID)
		if cerr == nil {
			total = len(chapters)
		}
	}

	return dto.ChapterContent{
		BookID:        bookID,
		Index:         index,
		Title:         NormalizeTitle(content.Title),
		HTML:          content.HTML,
		Images:        content.Images,
		PrevIndex:     index - 1,
		NextIndex:     nextIndex(index, total),
		TotalChapters: total,
	}, nil
}

// SaveProgress 保存阅读进度。
func (s *ReaderService) SaveProgress(ctx context.Context, bookID int64, chapterIndex int, chapterTitle string, chapterPos int, scrollPercent float64) error {
	return s.shelf.SaveProgress(ctx, bookID, chapterIndex, chapterTitle, chapterPos, scrollPercent)
}

// GetProgress 读取上次的阅读位置。
func (s *ReaderService) GetProgress(ctx context.Context, bookID int64) (dto.ReadingPosition, error) {
	return s.shelf.GetProgress(ctx, bookID)
}

// SyncOutline 回写书籍目录。
//
// 用途：PDF 的大纲与页数由前端（pdf.js）解析后回传——浏览器解析 PDF
// 的能力远强于任何 Go 库（尤其涉及 CJK 字体时），后端只负责存储。
// EPUB/TXT 等格式同样可用它来修正目录。
func (s *ReaderService) SyncOutline(ctx context.Context, bookID int64, items []dto.ChapterItem) error {
	if bookID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	if len(items) == 0 {
		return fmt.Errorf("%w: 目录不能为空", domain.ErrInvalidArgument)
	}

	chapters := make([]*domain.BookChapter, 0, len(items))
	for i, it := range items {
		chapters = append(chapters, &domain.BookChapter{
			BookID:   bookID,
			Index:    i,
			Title:    strings.TrimSpace(it.Title),
			URL:      it.URL,
			Resource: it.URL, // PDF/漫画场景下用 URL 作为定位键
			IsVolume: it.IsVolume,
		})
	}

	return s.uow.Do(ctx, func(ctx context.Context) error {
		return s.chapters.ReplaceAll(ctx, bookID, chapters)
	})
}

// nextIndex 计算下一章序号；已是最后一章时返回 -1。
func nextIndex(index, total int) int {
	if total > 0 && index >= total-1 {
		return -1
	}
	return index + 1
}
