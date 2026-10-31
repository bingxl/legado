package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
)

// ReplaceRuleAPI 暴露全局替换规则的管理能力。
type ReplaceRuleAPI struct {
	svc replaceRuleService
}

// replaceRuleService 是替换规则服务的能力契约。
type replaceRuleService interface {
	List(ctx context.Context) ([]dto.ReplaceRuleView, error)
	Get(ctx context.Context, id int64) (dto.ReplaceRuleView, error)
	Save(ctx context.Context, id int64, name, group, raw string, enabled bool, order int) (dto.ReplaceRuleView, error)
	Delete(ctx context.Context, id int64) error
	SetEnabled(ctx context.Context, id int64, enabled bool) error
	Import(ctx context.Context, data []byte, overwrite bool) (*dto.ReplaceRuleImportResult, error)
	Export(ctx context.Context, ids []int64) ([]byte, error)
}

// NewReplaceRuleAPI 创建替换规则绑定服务。
func NewReplaceRuleAPI(svc replaceRuleService) *ReplaceRuleAPI {
	return &ReplaceRuleAPI{svc: svc}
}

// List 列出全部替换规则。
func (a *ReplaceRuleAPI) List() ([]dto.ReplaceRuleView, error) {
	return a.svc.List(newCtx())
}

// Get 获取单条替换规则。
func (a *ReplaceRuleAPI) Get(id int64) (dto.ReplaceRuleView, error) {
	if id == 0 {
		return dto.ReplaceRuleView{}, errBadRequest("缺少规则 ID")
	}
	return a.svc.Get(newCtx(), id)
}

// Save 新增或更新替换规则；id 为 0 表示新增。
func (a *ReplaceRuleAPI) Save(id int64, name string, group string, raw string, enabled bool, order int) (dto.ReplaceRuleView, error) {
	return a.svc.Save(newCtx(), id, name, group, raw, enabled, order)
}

// Delete 删除替换规则。
func (a *ReplaceRuleAPI) Delete(id int64) error {
	if id == 0 {
		return errBadRequest("缺少规则 ID")
	}
	return a.svc.Delete(newCtx(), id)
}

// SetEnabled 启停单条替换规则。
func (a *ReplaceRuleAPI) SetEnabled(id int64, enabled bool) error {
	if id == 0 {
		return errBadRequest("缺少规则 ID")
	}
	return a.svc.SetEnabled(newCtx(), id, enabled)
}

// Import 导入替换规则文本（JSON 数组或换行分隔的 JSON）。
//
// 前端读取文件后把内容传进来，而不是传路径：安卓端的文件选择返回的是
// 内容 URI，后端按路径读不一定有权限。
func (a *ReplaceRuleAPI) Import(payload string, overwrite bool) (*dto.ReplaceRuleImportResult, error) {
	if payload == "" {
		return nil, errBadRequest("导入内容为空")
	}
	return a.svc.Import(newCtx(), []byte(payload), overwrite)
}

// Export 导出替换规则为 JSON 文本；ids 为空表示全部。
func (a *ReplaceRuleAPI) Export(ids []int64) (string, error) {
	data, err := a.svc.Export(newCtx(), ids)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
