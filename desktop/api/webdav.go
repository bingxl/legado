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
	// 以下四个方法服务于「从 WebDAV 选择并导入书籍」。
	ScanBooks(ctx context.Context, relPath string) ([]dto.RemoteBookView, error)
	StartBookImport(ctx context.Context, relPaths []string, groupID int64) (dto.WebDAVImportJob, error)
	CancelBookImport() error
	ImportStatus() dto.WebDAVImportJob
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

// ScanBooks 递归扫描远端目录下的书籍文件（txt / epub / pdf / zip / cbz 等）。
//
// relPath 为空表示工作根目录。返回的 Path 相对工作根目录，可直接回传给 StartBookImport。
func (a *WebDAVAPI) ScanBooks(relPath string) ([]dto.RemoteBookView, error) {
	books, err := a.svc.ScanBooks(newCtx(), relPath)
	if err != nil {
		return nil, err
	}
	if books == nil {
		books = []dto.RemoteBookView{}
	}
	return books, nil
}

// StartBookImport 后台下载并导入所选文件/目录，立即返回任务快照。
//
// 进度经 webdav:import:progress 事件推送；也可用 BookImportStatus 轮询兜底。
func (a *WebDAVAPI) StartBookImport(relPaths []string, groupID int64) (dto.WebDAVImportJob, error) {
	if len(relPaths) == 0 {
		return dto.WebDAVImportJob{}, errBadRequest("请先选择要导入的文件或目录")
	}
	return a.svc.StartBookImport(newCtx(), relPaths, groupID)
}

// CancelBookImport 取消正在进行的导入任务。
func (a *WebDAVAPI) CancelBookImport() error {
	return a.svc.CancelBookImport()
}

// BookImportStatus 返回当前（或最近一次）导入任务的状态。
func (a *WebDAVAPI) BookImportStatus() dto.WebDAVImportJob {
	return a.svc.ImportStatus()
}
