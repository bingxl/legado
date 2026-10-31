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
	// EventSourceDebug 书源调试打点，payload 为 dto.DebugEntryView（每条一行）。
	EventSourceDebug = "source:debug"
	// EventSourceDebugDone 书源调试结束，payload 为 dto.DebugDoneView。
	EventSourceDebugDone = "source:debug:done"
	// EventDownloadProgress 章节下载进度，payload 为 dto.DownloadProgress。
	EventDownloadProgress = "download:progress"
	// EventCacheProgress 章节缓存进度，payload 为 dto.CacheProgress。
	EventCacheProgress = "cache:progress"
	// EventWebDAVSyncProgress WebDAV 同步进度，payload 为 dto.SyncProgress。
	EventWebDAVSyncProgress = "webdav:sync:progress"
	// EventWebDAVImportProgress 从 WebDAV 导入书籍的进度，payload 为 dto.WebDAVImportProgress。
	EventWebDAVImportProgress = "webdav:import:progress"
	// EventAIIndexProgress AI 索引进度，payload 为 dto.AIIndexProgress。
	EventAIIndexProgress = "ai:index:progress"
	// EventAIAnswerChunk 流式回答的分片，payload 为 dto.AIAnswerChunk。
	EventAIAnswerChunk = "ai:answer:chunk"
	// EventAIAnswerDone 流式回答结束，payload 为 dto.AIAnswerDone。
	EventAIAnswerDone = "ai:answer:done"
)
