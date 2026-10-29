package port

import "context"

// SettingsStore 提供应用级键值配置能力（WebDAV 配置、阅读偏好等）。
//
// 之所以单独抽象而非散落在各处，是为了让配置读写有统一入口，
// 便于后续切换到加密存储或云端同步。
type SettingsStore interface {
	// Get 读取配置；不存在返回 domain.ErrNotFound。
	Get(ctx context.Context, key string) (string, error)
	// Set 写入配置（upsert）。
	Set(ctx context.Context, key, value string) error
	// Delete 删除配置。
	Delete(ctx context.Context, key string) error
}

// 配置项键名常量。集中定义以避免拼写错误散落各处。
const (
	// SettingWebDAV 保存 WebDAV 配置的 JSON。
	SettingWebDAV = "webdav.config"
	// SettingReadTheme 保存阅读器主题偏好。
	SettingReadTheme = "reader.theme"
	// SettingLastImportDir 记录最近一次导入目录。
	SettingLastImportDir = "import.lastDir"
	// SettingLastExportDir 记录最近一次导出目录。
	SettingLastExportDir = "export.lastDir"
)
