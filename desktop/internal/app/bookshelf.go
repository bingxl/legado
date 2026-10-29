// Package app 是应用服务层，承载用例编排与事务边界。
//
// 硬性约束（ARCHITECTURE.md R2）：本包**不得 import Wails**。
// 所有对外依赖都通过 internal/port 的接口注入，因此业务逻辑可以脱离 GUI
// 进行单元测试，也能被 CLI 或 server 模式复用。
package app

import (
	"context"
	"fmt"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// BookshelfService 负责书架的组织：分组管理与阅读进度维护。
type BookshelfService struct {
	books    port.BookRepository
	groups   port.BookGroupRepository
	progress port.ProgressRepository
	uow      port.UnitOfWork
}

// NewBookshelfService 构造书架服务，依赖由调用方注入。
func NewBookshelfService(
	books port.BookRepository,
	groups port.BookGroupRepository,
	progress port.ProgressRepository,
	uow port.UnitOfWork,
) *BookshelfService {
	return &BookshelfService{books: books, groups: groups, progress: progress, uow: uow}
}

// ListGroups 列出可显示的书架分组。
//
// 内置分组（迁移脚本种的 id=1「全部」）只是「未分组书籍」的默认容器，
// 界面上由「全部」（groupID=0，返回所有书）代表，因此不再下发，
// 否则侧栏会出现两个「全部」。用户自建分组不受影响。
func (s *BookshelfService) ListGroups(ctx context.Context) ([]dto.BookGroupView, error) {
	groups, err := s.groups.List(ctx)
	if err != nil {
		return nil, fmt.Errorf("查询分组失败: %w", err)
	}
	visible := make([]*domain.BookGroup, 0, len(groups))
	for _, g := range groups {
		if g.BuiltIn {
			continue
		}
		visible = append(visible, g)
	}
	return dto.NewBookGroupViews(visible), nil
}

// ListBooks 列出指定分组的书籍；groupID 为 0 时返回全部。
func (s *BookshelfService) ListBooks(ctx context.Context, groupID int64) ([]dto.BookBrief, error) {
	books, err := s.books.List(ctx, groupID)
	if err != nil {
		return nil, fmt.Errorf("查询书架失败: %w", err)
	}
	return dto.NewBookBriefs(books), nil
}

// GetBook 获取书籍详情。
func (s *BookshelfService) GetBook(ctx context.Context, id int64) (dto.BookDetail, error) {
	b, err := s.books.Get(ctx, id)
	if err != nil {
		return dto.BookDetail{}, err
	}
	return dto.NewBookDetail(b), nil
}

// DeleteBook 从书架移除书籍（章节与进度由级联删除清理）。
func (s *BookshelfService) DeleteBook(ctx context.Context, id int64) error {
	if id == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	return s.books.Delete(ctx, id)
}

// MoveToGroup 将书籍移动到指定分组。
func (s *BookshelfService) MoveToGroup(ctx context.Context, bookID, groupID int64) error {
	b, err := s.books.Get(ctx, bookID)
	if err != nil {
		return err
	}
	b.GroupID = groupID
	b.Order = 0
	return s.books.Update(ctx, b)
}

// SaveProgress 保存阅读进度。
//
// 同时写入 books 表（供书架列表展示）与 reading_progress 表（供阅读器精确恢复），
// 两者在同一事务内完成，避免读到不一致的中间状态。
func (s *BookshelfService) SaveProgress(ctx context.Context, bookID int64, chapterIndex int, chapterTitle string, chapterPos int, scrollPercent float64) error {
	if bookID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	return s.uow.Do(ctx, func(ctx context.Context) error {
		if err := s.books.UpdateProgress(ctx, bookID, chapterIndex, chapterTitle, chapterPos); err != nil {
			return err
		}
		return s.progress.Save(ctx, &domain.ReadingProgress{
			BookID:        bookID,
			ChapterIndex:  chapterIndex,
			ChapterTitle:  chapterTitle,
			ChapterPos:    chapterPos,
			ScrollPercent: scrollPercent,
		})
	})
}

// GetProgress 读取阅读进度；无记录时返回 ChapterIndex 为 -1 的空位置。
func (s *BookshelfService) GetProgress(ctx context.Context, bookID int64) (dto.ReadingPosition, error) {
	if bookID == 0 {
		return dto.ReadingPosition{}, fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	p, err := s.progress.Get(ctx, bookID)
	if err == domain.ErrNotFound {
		// 尚未产生阅读记录属于正常情况，返回空位置而非报错。
		return dto.ReadingPosition{BookID: bookID, ChapterIndex: -1}, nil
	}
	if err != nil {
		return dto.ReadingPosition{}, err
	}
	return dto.NewReadingPosition(p), nil
}

// CreateGroup 新建书架分组。
func (s *BookshelfService) CreateGroup(ctx context.Context, name string) (dto.BookGroupView, error) {
	g := &domain.BookGroup{Name: name, Show: true}
	if err := s.groups.Create(ctx, g); err != nil {
		return dto.BookGroupView{}, err
	}
	return dto.NewBookGroupView(g), nil
}

// UpdateGroup 更新书架分组。
func (s *BookshelfService) UpdateGroup(ctx context.Context, id int64, name string, show bool, order int) error {
	g, err := s.groups.Get(ctx, id)
	if err != nil {
		return err
	}
	g.Name = name
	g.Show = show
	g.Order = order
	return s.groups.Update(ctx, g)
}

// DeleteGroup 删除书架分组，并把组内书籍移回未分组。
func (s *BookshelfService) DeleteGroup(ctx context.Context, id int64) error {
	return s.uow.Do(ctx, func(ctx context.Context) error {
		if err := s.groups.Delete(ctx, id); err != nil {
			return err
		}
		// 组内书籍改为未分组，避免产生悬空引用。
		books, err := s.books.List(ctx, id)
		if err != nil {
			return err
		}
		for _, b := range books {
			b.GroupID = 0
			if err := s.books.Update(ctx, b); err != nil {
				return err
			}
		}
		return nil
	})
}
