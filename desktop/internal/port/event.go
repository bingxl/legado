package port

import "context"

// EventBus 向前端推送实时事件。
//
// 之所以抽象成接口，是为了让 internal/app 层不必 import Wails
// （见 ARCHITECTURE.md R2）。Wails 实现放在 adapter/eventwails。
type EventBus interface {
	// Emit 广播一个事件，payload 需可 JSON 序列化。
	Emit(ctx context.Context, name string, payload any) error
}

// 事件名称常量。前端通过 src/api 订阅同名事件，避免魔法字符串散落各处。
const (
	// EventImportProgress 书籍导入进度，payload 为 dto.ImportProgress。
	EventImportProgress = "import:progress"
	// EventSourceCheckProgress 书源校验进度，payload 为 dto.SourceCheckProgress。
	EventSourceCheckProgress = "source:check:progress"
	// EventDownloadProgress 章节下载进度，payload 为 dto.DownloadProgress。
	EventDownloadProgress = "download:progress"
	// EventWebDAVSyncProgress WebDAV 同步进度，payload 为 dto.SyncProgress。
	EventWebDAVSyncProgress = "webdav:sync:progress"
)
