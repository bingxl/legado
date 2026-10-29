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
