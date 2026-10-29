package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/port"
)

// SourceAPI 暴露书源管理能力。
type SourceAPI struct {
	svc sourceService
}

// sourceService 是书源服务的能力契约。
type sourceService interface {
	List(ctx context.Context, group string) ([]dto.SourceView, error)
	Get(ctx context.Context, id int64) (dto.SourceView, error)
	Save(ctx context.Context, id int64, name, group, url, comment, raw string, enabled bool, order int) (dto.SourceView, error)
	Delete(ctx context.Context, id int64) error
	SetEnabled(ctx context.Context, id int64, enabled bool) error
	Import(ctx context.Context, data []byte, overwrite bool) (*dto.SourceImportResult, error)
	Export(ctx context.Context, ids []int64) ([]byte, error)
	Validate(ctx context.Context, ids []int64, items port.CheckItems) ([]dto.SourceCheckResult, error)
	Search(ctx context.Context, sourceID int64, keyword string, page int) ([]dto.SearchResultView, error)
	SearchAll(ctx context.Context, keyword string, page int) ([]dto.SearchResultView, error)
	ListExploreSources(ctx context.Context) ([]dto.ExploreSourceBrief, error)
	ExploreKinds(ctx context.Context, sourceID int64) ([]dto.ExploreKindView, error)
	Explore(ctx context.Context, sourceID int64, url string, page int) ([]dto.SearchResultView, error)
	AddToShelf(ctx context.Context, sourceID int64, bookURL string, name string, author string, groupID int64) (dto.BookBrief, error)
}

// NewSourceAPI 创建书源绑定服务。
func NewSourceAPI(svc sourceService) *SourceAPI {
	return &SourceAPI{svc: svc}
}

// List 列出书源；group 为空表示全部。
func (a *SourceAPI) List(group string) ([]dto.SourceView, error) {
	return a.svc.List(newCtx(), group)
}

// Get 获取单个书源。
func (a *SourceAPI) Get(id int64) (dto.SourceView, error) {
	if id == 0 {
		return dto.SourceView{}, errBadRequest("缺少书源 ID")
	}
	return a.svc.Get(newCtx(), id)
}

// Save 新增或更新书源；id 为 0 表示新增。
func (a *SourceAPI) Save(id int64, name string, group string, url string, comment string, raw string, enabled bool, order int) (dto.SourceView, error) {
	return a.svc.Save(newCtx(), id, name, group, url, comment, raw, enabled, order)
}

// Delete 删除书源。
func (a *SourceAPI) Delete(id int64) error {
	if id == 0 {
		return errBadRequest("缺少书源 ID")
	}
	return a.svc.Delete(newCtx(), id)
}

// SetEnabled 启停书源。
func (a *SourceAPI) SetEnabled(id int64, enabled bool) error {
	if id == 0 {
		return errBadRequest("缺少书源 ID")
	}
	return a.svc.SetEnabled(newCtx(), id, enabled)
}

// Import 导入书源 JSON。
//
// 入参为字符串而非字节切片：Wails 绑定对 string 的传递更直观。
func (a *SourceAPI) Import(payload string, overwrite bool) (*dto.SourceImportResult, error) {
	if payload == "" {
		return nil, errBadRequest("导入内容为空")
	}
	return a.svc.Import(newCtx(), []byte(payload), overwrite)
}

// Export 导出书源为 JSON 字符串；ids 为空表示全部。
func (a *SourceAPI) Export(ids []int64) (string, error) {
	data, err := a.svc.Export(newCtx(), ids)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// Validate 校验书源；ids 为空表示校验全部启用书源。
func (a *SourceAPI) Validate(ids []int64) ([]dto.SourceCheckResult, error) {
	return a.svc.Validate(newCtx(), ids, port.CheckAll())
}

// Search 在单个书源内搜索。
func (a *SourceAPI) Search(sourceID int64, keyword string, page int) ([]dto.SearchResultView, error) {
	if sourceID == 0 {
		return nil, errBadRequest("缺少书源 ID")
	}
	if page < 1 {
		page = 1
	}
	return a.svc.Search(newCtx(), sourceID, keyword, page)
}

// SearchAll 在全部启用书源中搜索。
func (a *SourceAPI) SearchAll(keyword string, page int) ([]dto.SearchResultView, error) {
	if page < 1 {
		page = 1
	}
	return a.svc.SearchAll(newCtx(), keyword, page)
}

// ListExploreSources 列出开启「发现」的书源（只含名字与分组）。
//
// 与 Search 不同，发现不需要关键词，进入页面时调用一次即可。
// 分类由 ExploreKinds 在展开书源时按需取——这也是原版的行为。
func (a *SourceAPI) ListExploreSources() ([]dto.ExploreSourceBrief, error) {
	return a.svc.ListExploreSources(newCtx())
}

// ExploreKinds 解析某个书源的发现分类，供前端展开书源时调用。
func (a *SourceAPI) ExploreKinds(sourceID int64) ([]dto.ExploreKindView, error) {
	if sourceID == 0 {
		return nil, errBadRequest("缺少书源 ID")
	}
	return a.svc.ExploreKinds(newCtx(), sourceID)
}

// Explore 拉取某个分类下的书单；url 为空表示用书源的首个分类。
func (a *SourceAPI) Explore(sourceID int64, url string, page int) ([]dto.SearchResultView, error) {
	if sourceID == 0 {
		return nil, errBadRequest("缺少书源 ID")
	}
	if page < 1 {
		page = 1
	}
	return a.svc.Explore(newCtx(), sourceID, url, page)
}

// AddToShelf 把搜索结果加入书架。
//
// name/author 来自列表页（搜索或发现）已经解析到的信息：书源的详情页规则
// 可能取不到书名（改版、需要登录等），此时用列表页的值兜底，
// 否则落库会因为「书名不能为空」直接失败。
func (a *SourceAPI) AddToShelf(sourceID int64, bookURL string, name string, author string, groupID int64) (dto.BookBrief, error) {
	if sourceID == 0 {
		return dto.BookBrief{}, errBadRequest("缺少书源 ID")
	}
	if bookURL == "" {
		return dto.BookBrief{}, errBadRequest("缺少书籍链接")
	}
	return a.svc.AddToShelf(newCtx(), sourceID, bookURL, name, author, groupID)
}
