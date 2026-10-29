package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
)

// WebDAVAPI 暴露 WebDAV 备份与文件浏览能力。
type WebDAVAPI struct {
	svc webdavService
}

// webdavService 是 WebDAV 服务的能力契约。
type webdavService interface {
	GetConfig(ctx context.Context) (dto.WebDAVConfigView, error)
	SaveConfig(ctx context.Context, url, username, password, rootPath string, autoSync bool) (dto.WebDAVConfigView, error)
	Test(ctx context.Context) error
	List(ctx context.Context, relPath string) ([]dto.WebDAVEntryView, error)
	UploadBackup(ctx context.Context) (dto.SyncProgress, error)
	DownloadBackup(ctx context.Context, remotePath, localDir string) (string, error)
	Delete(ctx context.Context, relPath string) error
}

// NewWebDAVAPI 创建 WebDAV 绑定服务。
func NewWebDAVAPI(svc webdavService) *WebDAVAPI {
	return &WebDAVAPI{svc: svc}
}

// GetConfig 读取配置（不含密码）。
func (a *WebDAVAPI) GetConfig() (dto.WebDAVConfigView, error) {
	return a.svc.GetConfig(newCtx())
}

// SaveConfig 保存配置。password 传空串表示保持原密码不变。
func (a *WebDAVAPI) SaveConfig(url string, username string, password string, rootPath string, autoSync bool) (dto.WebDAVConfigView, error) {
	return a.svc.SaveConfig(newCtx(), url, username, password, rootPath, autoSync)
}

// Test 测试连接是否可用。
func (a *WebDAVAPI) Test() error {
	return a.svc.Test(newCtx())
}

// List 列出远端目录。
func (a *WebDAVAPI) List(relPath string) ([]dto.WebDAVEntryView, error) {
	return a.svc.List(newCtx(), relPath)
}

// UploadBackup 上传当前数据库备份。
func (a *WebDAVAPI) UploadBackup() (dto.SyncProgress, error) {
	return a.svc.UploadBackup(newCtx())
}

// DownloadBackup 下载远端备份到本地目录。
func (a *WebDAVAPI) DownloadBackup(remotePath string, localDir string) (string, error) {
	if remotePath == "" {
		return "", errBadRequest("缺少远端文件路径")
	}
	return a.svc.DownloadBackup(newCtx(), remotePath, localDir)
}

// Delete 删除远端文件。
func (a *WebDAVAPI) Delete(relPath string) error {
	if relPath == "" {
		return errBadRequest("缺少远端文件路径")
	}
	return a.svc.Delete(newCtx(), relPath)
}
