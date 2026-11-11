package dto

// ImportProgress 通过事件推送给前端的导入进度。
// 对应 port.EventImportProgress。
type ImportProgress struct {
	Total   int    `json:"total"`
	Done    int    `json:"done"`
	Current string `json:"current"` // 当前处理的文件名
}

// ImportFailure 描述导入失败的一个文件。
type ImportFailure struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

// ImportResult 是批量导入的汇总结果。
// 采用「部分成功」语义：个别文件失败不中断整体流程，由 Failures 反馈。
type ImportResult struct {
	Imported []BookBrief     `json:"imported"`
	Failed   []ImportFailure `json:"failed"`
}

// HasFailure 报告是否存在导入失败项。
func (r *ImportResult) HasFailure() bool { return len(r.Failed) > 0 }

// ExportResult 描述一次导出的产物。
type ExportResult struct {
	Path   string `json:"path"`
	Format string `json:"format"`
	Size   int64  `json:"size"`
}

// SyncProgress 通过事件推送的 WebDAV 同步进度。
// 对应 port.EventWebDAVSyncProgress。
type SyncProgress struct {
	Phase   string `json:"phase"` // 阶段：upload | download | done | error
	Total   int    `json:"total"`
	Done    int    `json:"done"`
	Message string `json:"message"` // 当前操作描述或错误原因
}

// SourceCheckProgress 通过事件推送的书源校验进度。
// 对应 port.EventSourceCheckProgress。
//
// 除了整体进度（Total/Done/Current），还带**单条结论**：原生书源管理页在
// 校验时每行显示自己的「成功/失败」文字与转圈，而不是只有一个总进度条。
// SourceID 为空（0）表示这是一条纯进度事件。
type SourceCheckProgress struct {
	Total    int    `json:"total"`
	Done     int    `json:"done"`
	Current  string `json:"current"`
	SourceID int64  `json:"sourceId"`
	OK       bool   `json:"ok"`
	Message  string `json:"message"`
}
