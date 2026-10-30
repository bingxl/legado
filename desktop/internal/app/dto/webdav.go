package dto

import (
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// WebDAVConfigView 是返回给前端的 WebDAV 配置视图。
//
// 安全约定：密码**永不返回**前端，仅以 HasPassword 指示是否已设置。
// 更新配置时若 Password 为空串，表示「保持原密码不变」。
type WebDAVConfigView struct {
	URL         string `json:"url"`
	Username    string `json:"username"`
	HasPassword bool   `json:"hasPassword"`
	RootPath    string `json:"rootPath"`
	AutoSync    bool   `json:"autoSync"`
	Configured  bool   `json:"configured"` // 是否已具备可用的连接信息
}

// NewWebDAVConfigView 从领域配置构造视图，剥离密码。
func NewWebDAVConfigView(c *domain.WebDAVConfig) WebDAVConfigView {
	if c == nil {
		return WebDAVConfigView{}
	}
	return WebDAVConfigView{
		URL:         c.URL,
		Username:    c.Username,
		HasPassword: c.Password != "",
		RootPath:    c.RootPath,
		AutoSync:    c.AutoSync,
		Configured:  c.URL != "",
	}
}

// WebDAVEntryView 是远端文件条目视图。
type WebDAVEntryView struct {
	Path    string     `json:"path"`
	Name    string     `json:"name"`
	IsDir   bool       `json:"isDir"`
	Size    int64      `json:"size"`
	ModTime *time.Time `json:"modTime"`
}

// NewWebDAVEntryView 转换远端文件条目。
func NewWebDAVEntryView(e port.WebDAVEntry) WebDAVEntryView {
	var mod *time.Time
	if !e.ModTime.IsZero() {
		t := e.ModTime
		mod = &t
	}
	return WebDAVEntryView{
		Path:    e.Path,
		Name:    e.Name,
		IsDir:   e.IsDir,
		Size:    e.Size,
		ModTime: mod,
	}
}

// NewWebDAVEntryViews 批量转换远端文件条目。
func NewWebDAVEntryViews(in []port.WebDAVEntry) []WebDAVEntryView {
	out := make([]WebDAVEntryView, 0, len(in))
	for _, e := range in {
		out = append(out, NewWebDAVEntryView(e))
	}
	return out
}

// RemoteBookView 是远端扫描到的一个可导入书籍文件。
type RemoteBookView struct {
	// Path 是相对 WebDAV 工作根目录的路径，前端原样回传给 StartImport。
	Path string `json:"path"`
	Name string `json:"name"`
	Size int64  `json:"size"`
	// Format 是归一化后的格式名（TXT / EPUB / PDF / Comic），便于前端显示。
	Format  string     `json:"format"`
	ModTime *time.Time `json:"modTime"`
}

// WebDAV 导入任务的状态取值。
const (
	WebDAVImportIdle     = "idle"
	WebDAVImportRunning  = "running"
	WebDAVImportDone     = "done"
	WebDAVImportCanceled = "canceled"
	WebDAVImportFailed   = "failed"
)

// WebDAVImportProgress 是导入过程的实时进度，通过事件推送。
//
// Phase 用来区分阶段：scan（统计文件数）/ download（传输字节）/ import（解析入库）/
// done / error。前端据此切换进度条的语义——扫描阶段没有总量，只能显示「正在统计」。
type WebDAVImportProgress struct {
	State      string `json:"state"`
	Phase      string `json:"phase"`
	Total      int    `json:"total"`
	Done       int    `json:"done"`
	Failed     int    `json:"failed"`
	Current    string `json:"current"`
	Bytes      int64  `json:"bytes"`
	TotalBytes int64  `json:"totalBytes"`
	Message    string `json:"message"`
}

// WebDAVImportJob 是一次导入任务的完整快照。
type WebDAVImportJob struct {
	State      string          `json:"state"`
	Phase      string          `json:"phase"`
	Total      int             `json:"total"`
	Done       int             `json:"done"`
	Failed     int             `json:"failed"`
	Current    string          `json:"current"`
	Bytes      int64           `json:"bytes"`
	TotalBytes int64           `json:"totalBytes"`
	Message    string          `json:"message"`
	Imported   []BookBrief     `json:"imported"`
	Failures   []ImportFailure `json:"failures"`
}

// Running 报告任务是否仍在进行。
func (j WebDAVImportJob) Running() bool { return j.State == WebDAVImportRunning }

// Percent 返回整体完成百分比（按文件数，0-100）。
//
// 扫描阶段总量未知，固定返回 0，由前端显示不确定进度条。
func (j WebDAVImportJob) Percent() int {
	if j.Total <= 0 {
		return 0
	}
	n := j.Done + j.Failed
	if n >= j.Total {
		return 100
	}
	return n * 100 / j.Total
}
