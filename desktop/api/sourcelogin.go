package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
)

// SourceLoginAPI 暴露书源（含漫画源）的登录能力。
//
// 单独一个绑定服务而不是塞进 SourceAPI：登录是一组自成体系的动作
// （取配置、跑脚本、粘贴 Cookie、探测状态），前端也用独立的对话框承载它。
type SourceLoginAPI struct {
	svc sourceLoginService
}

// sourceLoginService 是登录服务的能力契约。
type sourceLoginService interface {
	Profile(ctx context.Context, sourceID int64) (dto.SourceLoginView, error)
	Login(ctx context.Context, sourceID int64, form map[string]string) (dto.LoginResult, error)
	RunAction(ctx context.Context, sourceID int64, action string, form map[string]string) (dto.LoginResult, error)
	SaveHeader(ctx context.Context, sourceID int64, header string) (dto.LoginResult, error)
	Header(ctx context.Context, sourceID int64) (string, error)
	Clear(ctx context.Context, sourceID int64, withForm bool) error
	Check(ctx context.Context, sourceID int64, probeURL string) (dto.LoginProbeView, error)
}

// NewSourceLoginAPI 创建登录绑定服务。
func NewSourceLoginAPI(svc sourceLoginService) *SourceLoginAPI {
	return &SourceLoginAPI{svc: svc}
}

// Profile 读取登录面板所需的全部信息。
func (a *SourceLoginAPI) Profile(sourceID int64) (dto.SourceLoginView, error) {
	if sourceID <= 0 {
		return dto.SourceLoginView{}, errBadRequest("缺少书源 ID")
	}
	return a.svc.Profile(newCtx(), sourceID)
}

// Login 执行登录；form 是登录框里填的值（键名来自 loginUi）。
func (a *SourceLoginAPI) Login(sourceID int64, form map[string]string) (dto.LoginResult, error) {
	if sourceID <= 0 {
		return dto.LoginResult{}, errBadRequest("缺少书源 ID")
	}
	return a.svc.Login(newCtx(), sourceID, form)
}

// RunAction 执行 loginUi 里自定义按钮的动作。
func (a *SourceLoginAPI) RunAction(sourceID int64, action string, form map[string]string) (dto.LoginResult, error) {
	if sourceID <= 0 {
		return dto.LoginResult{}, errBadRequest("缺少书源 ID")
	}
	return a.svc.RunAction(newCtx(), sourceID, action, form)
}

// SaveHeader 保存手动粘贴的登录头（JSON / 请求头行 / 裸 Cookie 都认）。
func (a *SourceLoginAPI) SaveHeader(sourceID int64, header string) (dto.LoginResult, error) {
	if sourceID <= 0 {
		return dto.LoginResult{}, errBadRequest("缺少书源 ID")
	}
	return a.svc.SaveHeader(newCtx(), sourceID, header)
}

// Header 读取已保存的登录头原文（供查看/复制）。
func (a *SourceLoginAPI) Header(sourceID int64) (string, error) {
	if sourceID <= 0 {
		return "", errBadRequest("缺少书源 ID")
	}
	return a.svc.Header(newCtx(), sourceID)
}

// Clear 清除登录；withForm 为 true 时连保存的账号密码一起删。
func (a *SourceLoginAPI) Clear(sourceID int64, withForm bool) error {
	if sourceID <= 0 {
		return errBadRequest("缺少书源 ID")
	}
	return a.svc.Clear(newCtx(), sourceID, withForm)
}

// Check 探测当前登录态；probeURL 为空时由后端按书源字段挑地址。
func (a *SourceLoginAPI) Check(sourceID int64, probeURL string) (dto.LoginProbeView, error) {
	if sourceID <= 0 {
		return dto.LoginProbeView{}, errBadRequest("缺少书源 ID")
	}
	return a.svc.Check(newCtx(), sourceID, probeURL)
}
