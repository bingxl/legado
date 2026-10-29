// Package api 是 Wails 的服务绑定层。
//
// 严格约束（ARCHITECTURE.md R1）：本层是**薄壳**，只允许做三件事——
//  1. 校验入参
//  2. 调用 internal/app 的应用服务
//  3. 转换 DTO 并包装错误
//
// 禁止在此编写 SQL、解析文件、编排业务流程。
// 修改本包的方法签名后，必须重新生成前端绑定：
//
//	wails3 generate bindings -ts
package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
)

// newCtx 返回一个背景上下文。
//
// Wails 绑定方法不接收 context（前端调用无法传递），
// 这里统一在绑定层创建，避免 app 层出现 context.TODO() 这类散落的写法。
func newCtx() context.Context { return context.Background() }

// BookshelfAPI 暴露书架管理能力给前端。
type BookshelfAPI struct {
	svc bookshelfService
}

// bookshelfService 是书架服务的能力契约，便于本层做单元测试替换。
type bookshelfService interface {
	ListGroups(ctx context.Context) ([]dto.BookGroupView, error)
	ListBooks(ctx context.Context, groupID int64) ([]dto.BookBrief, error)
	GetBook(ctx context.Context, id int64) (dto.BookDetail, error)
	DeleteBook(ctx context.Context, id int64) error
	MoveToGroup(ctx context.Context, bookID, groupID int64) error
	SaveProgress(ctx context.Context, bookID int64, chapterIndex int, chapterTitle string, chapterPos int, scrollPercent float64) error
	GetProgress(ctx context.Context, bookID int64) (dto.ReadingPosition, error)
	CreateGroup(ctx context.Context, name string) (dto.BookGroupView, error)
	UpdateGroup(ctx context.Context, id int64, name string, show bool, order int) error
	DeleteGroup(ctx context.Context, id int64) error
}

// NewBookshelfAPI 创建书架绑定服务。
func NewBookshelfAPI(svc bookshelfService) *BookshelfAPI {
	return &BookshelfAPI{svc: svc}
}

// ListGroups 返回全部书架分组。
func (a *BookshelfAPI) ListGroups() ([]dto.BookGroupView, error) {
	return a.svc.ListGroups(newCtx())
}

// ListBooks 列出分组下的书籍；groupID 传 0 表示全部。
func (a *BookshelfAPI) ListBooks(groupID int64) ([]dto.BookBrief, error) {
	return a.svc.ListBooks(newCtx(), groupID)
}

// GetBook 获取书籍详情。
func (a *BookshelfAPI) GetBook(id int64) (dto.BookDetail, error) {
	return a.svc.GetBook(newCtx(), id)
}

// DeleteBook 从书架移除书籍。
func (a *BookshelfAPI) DeleteBook(id int64) error {
	return a.svc.DeleteBook(newCtx(), id)
}

// MoveToGroup 把书籍移动到指定分组。
func (a *BookshelfAPI) MoveToGroup(bookID int64, groupID int64) error {
	return a.svc.MoveToGroup(newCtx(), bookID, groupID)
}

// CreateGroup 新建分组。
func (a *BookshelfAPI) CreateGroup(name string) (dto.BookGroupView, error) {
	return a.svc.CreateGroup(newCtx(), name)
}

// UpdateGroup 更新分组。
func (a *BookshelfAPI) UpdateGroup(id int64, name string, show bool, order int) error {
	return a.svc.UpdateGroup(newCtx(), id, name, show, order)
}

// DeleteGroup 删除分组。
func (a *BookshelfAPI) DeleteGroup(id int64) error {
	return a.svc.DeleteGroup(newCtx(), id)
}
