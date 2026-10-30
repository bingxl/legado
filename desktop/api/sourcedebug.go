package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
)

// SourceDebugAPI 暴露书源调试能力。
//
// 调试是异步的：Start 立即返回会话 ID，随后通过 source:debug / source:debug:done
// 两个事件持续推送打点，前端把消息按行追加到输出面板即可。
type SourceDebugAPI struct {
	svc sourceDebugService
}

// sourceDebugService 是书源调试服务的能力契约。
type sourceDebugService interface {
	Start(ctx context.Context, sourceID int64, rawJSON string, key string, stage string) (dto.DebugSessionView, error)
	Stop()
	Running() dto.DebugSessionView
}

// NewSourceDebugAPI 创建书源调试绑定服务。
func NewSourceDebugAPI(svc sourceDebugService) *SourceDebugAPI {
	return &SourceDebugAPI{svc: svc}
}

// Start 开始调试。
//
// sourceID 与 rawJSON 二选一：rawJSON 非空时以它为准（编辑页未保存的草稿也能调试），
// 否则按 sourceID 取库里已保存的书源。
//
// key 是调试入口，形态决定从哪一步开始：
//   - 普通关键字       搜索，然后顺着详情 → 目录 → 正文往下跑
//   - 绝对 URL         从详情页开始
//   - "分类::地址"      发现页（地址留空则按分类名查 exploreUrl）
//   - "++地址"         从目录页开始
//   - "--地址"         从正文页开始
//
// stage 控制最深跑到哪一步：search / explore / info / toc / content（默认）。
func (a *SourceDebugAPI) Start(sourceID int64, rawJSON string, key string, stage string) (dto.DebugSessionView, error) {
	if sourceID == 0 && rawJSON == "" {
		return dto.DebugSessionView{}, errBadRequest("缺少书源")
	}
	return a.svc.Start(newCtx(), sourceID, rawJSON, key, stage)
}

// Stop 停止当前调试。引擎会在当前阶段结束后退出，因此这里是异步的。
func (a *SourceDebugAPI) Stop() error {
	a.svc.Stop()
	return nil
}

// Running 返回当前调试会话；Running 为 false 表示空闲。
func (a *SourceDebugAPI) Running() (dto.DebugSessionView, error) {
	return a.svc.Running(), nil
}
