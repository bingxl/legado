package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
)

// AudioAPI 暴露听书能力：地址解析、离线下载、缓存管理与播放态广播。
//
// 真正的音频流不经过绑定层——前端拿到 /stream/<sid> 后由 AssetServer 直出，
// 避免把整段音频编码进 Wails 的 JSON 往返。播放态则相反：它是极小的状态快照，
// 走绑定上报 + Go 事件广播，宿主与其它窗口据此对齐。
type AudioAPI struct {
	svc audioService
}

type audioService interface {
	ResolvePlayURL(ctx context.Context, bookID int64, index int) (*dto.PlayURL, error)
	DownloadAudio(ctx context.Context, bookID int64, fromIndex, toIndex int) (*dto.AudioDownloadView, error)
	CancelDownload(ctx context.Context, bookID int64) error
	CachedAudio(ctx context.Context, bookID int64) ([]dto.AudioCacheView, error)
	DeleteAudioCache(ctx context.Context, bookID int64, indexes []int) error
	ReportPlaybackState(ctx context.Context, st dto.AudioPlaybackState) (dto.AudioPlaybackState, error)
	PlaybackState() dto.AudioPlaybackState
}

func NewAudioAPI(svc audioService) *AudioAPI { return &AudioAPI{svc: svc} }

// ResolvePlayURL 解析一章的音频地址，返回同域代理 URL。
// 每次切章都要重新调用：直链有时效，且旧会话会被淘汰。
func (a *AudioAPI) ResolvePlayURL(bookID int64, index int) (dto.PlayURL, error) {
	if bookID == 0 {
		return dto.PlayURL{}, errBadRequest("缺少书籍 ID")
	}
	if index < 0 {
		return dto.PlayURL{}, errBadRequest("章节序号不能为负")
	}
	out, err := a.svc.ResolvePlayURL(newCtx(), bookID, index)
	if err != nil {
		return dto.PlayURL{}, err
	}
	return *out, nil
}

// DownloadAudio 后台下载 [fromIndex, toIndex] 章节的音频。
func (a *AudioAPI) DownloadAudio(bookID int64, fromIndex, toIndex int) (dto.AudioDownloadView, error) {
	if bookID == 0 {
		return dto.AudioDownloadView{}, errBadRequest("缺少书籍 ID")
	}
	if fromIndex < 0 || toIndex < fromIndex {
		return dto.AudioDownloadView{}, errBadRequest("下载章节范围不合法")
	}
	out, err := a.svc.DownloadAudio(newCtx(), bookID, fromIndex, toIndex)
	if err != nil {
		return dto.AudioDownloadView{}, err
	}
	return *out, nil
}

// CancelDownload 取消该书正在进行的音频下载。
func (a *AudioAPI) CancelDownload(bookID int64) error {
	if bookID == 0 {
		return errBadRequest("缺少书籍 ID")
	}
	return a.svc.CancelDownload(newCtx(), bookID)
}

// CachedAudio 列出已离线缓存的章节。
func (a *AudioAPI) CachedAudio(bookID int64) ([]dto.AudioCacheView, error) {
	if bookID == 0 {
		return nil, errBadRequest("缺少书籍 ID")
	}
	return a.svc.CachedAudio(newCtx(), bookID)
}

// DeleteAudioCache 删除指定章节的离线音频。
func (a *AudioAPI) DeleteAudioCache(bookID int64, indexes []int) error {
	if bookID == 0 {
		return errBadRequest("缺少书籍 ID")
	}
	if len(indexes) == 0 {
		return errBadRequest("未指定章节")
	}
	return a.svc.DeleteAudioCache(newCtx(), bookID, indexes)
}

// ReportPlaybackState 上报播放态并触发 audio:playback:state 广播。
// 返回服务端补过 seq 的快照，前端可据此判断事件是否过期。
func (a *AudioAPI) ReportPlaybackState(st dto.AudioPlaybackState) (dto.AudioPlaybackState, error) {
	return a.svc.ReportPlaybackState(newCtx(), st)
}

// PlaybackState 查询当前播放态快照，供冷启动与宿主侧对齐。
func (a *AudioAPI) PlaybackState() (dto.AudioPlaybackState, error) {
	return a.svc.PlaybackState(), nil
}
