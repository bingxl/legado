package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// WebDAVService 负责 WebDAV 连接配置的维护，以及备份文件的上传与下载。
//
// 关于「同步」的取舍：直接覆盖运行中的数据库风险过高（会破坏当前会话状态），
// 因此本服务只提供备份的上传/下载，恢复动作由用户显式确认后重启应用完成。
type WebDAVService struct {
	settings port.SettingsStore
	factory  port.WebDAVClientFactory
	events   port.EventBus
	// dbPath 是本地数据库文件路径，用于备份上传。
	dbPath string
}

// NewWebDAVService 构造 WebDAV 服务。dbPath 为本地数据库路径（可为空）。
func NewWebDAVService(settings port.SettingsStore, factory port.WebDAVClientFactory, events port.EventBus, dbPath string) *WebDAVService {
	return &WebDAVService{settings: settings, factory: factory, events: events, dbPath: dbPath}
}

// GetConfig 读取当前配置；密码不返回前端（见 dto.WebDAVConfigView）。
func (s *WebDAVService) GetConfig(ctx context.Context) (dto.WebDAVConfigView, error) {
	cfg, err := s.load(ctx)
	if err != nil {
		// 尚未配置属于正常初始状态，返回空视图而非报错。
		if err == domain.ErrNotFound {
			return dto.WebDAVConfigView{}, nil
		}
		return dto.WebDAVConfigView{}, err
	}
	return dto.NewWebDAVConfigView(cfg), nil
}

// SaveConfig 保存配置。
//
// 密码字段为空串时表示「保持原密码不变」，这样前端无需回填密码即可修改其他项。
func (s *WebDAVService) SaveConfig(ctx context.Context, url, username, password, rootPath string, autoSync bool) (dto.WebDAVConfigView, error) {
	if url == "" {
		return dto.WebDAVConfigView{}, fmt.Errorf("%w: 服务地址不能为空", domain.ErrInvalidArgument)
	}
	cfg := domain.WebDAVConfig{
		URL:      strings.TrimRight(url, "/"),
		Username: username,
		Password: password,
		RootPath: rootPath,
		AutoSync: autoSync,
	}
	if cfg.Password == "" {
		if old, err := s.load(ctx); err == nil {
			cfg.Password = old.Password
		}
	}
	if cfg.RootPath == "" {
		cfg.RootPath = "legado-desktop"
	}
	if err := s.persist(ctx, &cfg); err != nil {
		return dto.WebDAVConfigView{}, err
	}
	return dto.NewWebDAVConfigView(&cfg), nil
}

// Test 测试连接：尝试列出根目录，成功即认为配置可用。
func (s *WebDAVService) Test(ctx context.Context) error {
	cfg, err := s.load(ctx)
	if err != nil {
		return err
	}
	client, err := s.factory.New(*cfg)
	if err != nil {
		return err
	}
	if _, err := client.List(ctx, s.remoteRoot(cfg)); err != nil {
		return fmt.Errorf("%w: %s", domain.ErrRemoteFailed, err.Error())
	}
	return nil
}

// List 列出远端目录下的条目。
func (s *WebDAVService) List(ctx context.Context, relPath string) ([]dto.WebDAVEntryView, error) {
	cfg, err := s.load(ctx)
	if err != nil {
		return nil, err
	}
	client, err := s.factory.New(*cfg)
	if err != nil {
		return nil, err
	}
	entries, err := client.List(ctx, joinRemote(s.remoteRoot(cfg), relPath))
	if err != nil {
		return nil, fmt.Errorf("%w: %s", domain.ErrRemoteFailed, err.Error())
	}
	return dto.NewWebDAVEntryViews(entries), nil
}

// UploadBackup 把当前数据库快照上传到远端 backups 目录。
//
// 使用 SQLite 的备份 API 更安全，但为保持纯 Go 依赖简洁，
// 这里采用文件复制：WAL 模式下需先 checkpoint，否则可能丢失未落盘数据。
func (s *WebDAVService) UploadBackup(ctx context.Context) (dto.SyncProgress, error) {
	cfg, err := s.load(ctx)
	if err != nil {
		return dto.SyncProgress{}, err
	}
	if s.dbPath == "" {
		return dto.SyncProgress{}, fmt.Errorf("%w: 未指定本地数据库路径", domain.ErrNotConfigured)
	}
	client, err := s.factory.New(*cfg)
	if err != nil {
		return dto.SyncProgress{}, err
	}

	src, err := os.Open(s.dbPath)
	if err != nil {
		return dto.SyncProgress{}, fmt.Errorf("打开数据库失败: %w", err)
	}
	defer src.Close()

	name := fmt.Sprintf("backup-%s.db", time.Now().Format("20060102-150405"))
	remote := joinRemote(s.remoteRoot(cfg), "backups/"+name)
	s.emit(ctx, "upload", 1, 0, "上传备份 "+name)

	if err := client.Upload(ctx, remote, src); err != nil {
		s.emit(ctx, "error", 1, 0, err.Error())
		return dto.SyncProgress{}, fmt.Errorf("%w: %s", domain.ErrRemoteFailed, err.Error())
	}

	progress := dto.SyncProgress{Phase: "done", Total: 1, Done: 1, Message: remote}
	s.emit(ctx, "done", 1, 1, "备份已上传")
	return progress, nil
}

// DownloadBackup 下载远端备份到本地目录。
//
// 注意：本方法**不会**替换运行中的数据库——那需要重启应用，由调用方另行确认。
func (s *WebDAVService) DownloadBackup(ctx context.Context, remotePath, localDir string) (string, error) {
	cfg, err := s.load(ctx)
	if err != nil {
		return "", err
	}
	client, err := s.factory.New(*cfg)
	if err != nil {
		return "", err
	}
	if localDir == "" {
		localDir, _ = os.UserHomeDir()
	}
	target := filepath.Join(localDir, path.Base(remotePath))
	if err := os.MkdirAll(localDir, 0o755); err != nil {
		return "", fmt.Errorf("创建本地目录失败: %w", err)
	}

	s.emit(ctx, "download", 1, 0, "下载 "+path.Base(remotePath))
	rc, err := client.Download(ctx, joinRemote(s.remoteRoot(cfg), remotePath))
	if err != nil {
		s.emit(ctx, "error", 1, 0, err.Error())
		return "", fmt.Errorf("%w: %s", domain.ErrRemoteFailed, err.Error())
	}
	defer rc.Close()

	f, err := os.Create(target)
	if err != nil {
		return "", fmt.Errorf("创建本地文件失败: %w", err)
	}
	defer f.Close()

	if _, err := io.Copy(f, rc); err != nil {
		return "", fmt.Errorf("写入本地文件失败: %w", err)
	}
	s.emit(ctx, "done", 1, 1, "已保存到 "+target)
	return target, nil
}

// Delete 删除远端文件。
func (s *WebDAVService) Delete(ctx context.Context, relPath string) error {
	cfg, err := s.load(ctx)
	if err != nil {
		return err
	}
	client, err := s.factory.New(*cfg)
	if err != nil {
		return err
	}
	if err := client.Delete(ctx, joinRemote(s.remoteRoot(cfg), relPath)); err != nil {
		return fmt.Errorf("%w: %s", domain.ErrRemoteFailed, err.Error())
	}
	return nil
}

// load 读取并反序列化配置。
func (s *WebDAVService) load(ctx context.Context) (*domain.WebDAVConfig, error) {
	if s.settings == nil {
		return nil, fmt.Errorf("%w: 未配置持久化存储", domain.ErrNotConfigured)
	}
	raw, err := s.settings.Get(ctx, port.SettingWebDAV)
	if err != nil {
		return nil, err
	}
	var cfg domain.WebDAVConfig
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return nil, fmt.Errorf("%w: 配置解析失败", domain.ErrNotConfigured)
	}
	if cfg.URL == "" {
		return nil, fmt.Errorf("%w: 尚未配置 WebDAV", domain.ErrNotConfigured)
	}
	return &cfg, nil
}

// persist 序列化并写入配置。
func (s *WebDAVService) persist(ctx context.Context, cfg *domain.WebDAVConfig) error {
	data, err := json.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("序列化配置失败: %w", err)
	}
	return s.settings.Set(ctx, port.SettingWebDAV, string(data))
}

// remoteRoot 计算远端工作根目录。
func (s *WebDAVService) remoteRoot(cfg *domain.WebDAVConfig) string {
	root := strings.Trim(cfg.RootPath, "/")
	if root == "" {
		root = "legado-desktop"
	}
	return "/" + root
}

// emit 推送同步进度；事件总线缺失时静默跳过。
func (s *WebDAVService) emit(ctx context.Context, phase string, total, done int, msg string) {
	if s.events == nil {
		return
	}
	_ = s.events.Emit(ctx, port.EventWebDAVSyncProgress, dto.SyncProgress{
		Phase:   phase,
		Total:   total,
		Done:    done,
		Message: msg,
	})
}

// joinRemote 拼接远端路径，确保以 / 开头。
func joinRemote(root, rel string) string {
	rel = strings.TrimPrefix(rel, "/")
	if rel == "" {
		return root
	}
	return strings.TrimSuffix(root, "/") + "/" + rel
}
