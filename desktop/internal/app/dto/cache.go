package dto

import "time"

// 缓存任务的四种状态。
const (
	CacheStateRunning  = "running"  // 正在缓存
	CacheStateDone     = "done"     // 已完成
	CacheStateCanceled = "canceled" // 用户取消
	CacheStateFailed   = "failed"   // 因不可恢复错误中断（个别章节失败不算）
)

// 缓存范围。
const (
	CacheScopeAll       = "all"       // 整本
	CacheScopeRemaining = "remaining" // 从当前阅读位置到结尾
	CacheScopeMissing   = "missing"   // 仅补齐缺失章节
	CacheScopeChapters  = "chapters"  // 指定章节（阅读器里的「缓存本章」）
)

// CacheJob 是一次缓存任务的快照。
type CacheJob struct {
	BookID     int64      `json:"bookId"`
	BookName   string     `json:"bookName"`
	Scope      string     `json:"scope"`
	State      string     `json:"state"`
	Total      int        `json:"total"`
	Done       int        `json:"done"`
	Failed     int        `json:"failed"`
	Message    string     `json:"message"` // 当前章节标题或最近一条错误
	StartedAt  time.Time  `json:"startedAt"`
	FinishedAt *time.Time `json:"finishedAt"`
}

// Percent 返回任务进度百分比（0~100），无章节时为 0。
func (j CacheJob) Percent() int {
	if j.Total <= 0 {
		return 0
	}
	pct := (j.Done + j.Failed) * 100 / j.Total
	if pct > 100 {
		pct = 100
	}
	return pct
}

// CacheProgress 通过事件推送的缓存进度。
// 对应 port.EventCacheProgress。
type CacheProgress struct {
	BookID   int64  `json:"bookId"`
	BookName string `json:"bookName"`
	State    string `json:"state"`
	Total    int    `json:"total"`
	Done     int    `json:"done"`
	Failed   int    `json:"failed"`
	Current  string `json:"current"` // 当前处理的章节标题
	Message  string `json:"message"`
}

// CacheBookView 是缓存管理列表中的一本书。
type CacheBookView struct {
	BookID         int64      `json:"bookId"`
	Name           string     `json:"name"`
	Author         string     `json:"author"`
	Cover          string     `json:"cover"`
	Kind           string     `json:"kind"`
	Format         string     `json:"format"`
	FormatLabel    string     `json:"formatLabel"`
	TotalChapters  int        `json:"totalChapters"`
	CachedChapters int        `json:"cachedChapters"`
	Size           int64      `json:"size"`
	UpdatedAt      *time.Time `json:"updatedAt"`
	Job            *CacheJob  `json:"job"` // 该书正在/最近一次运行的任务
}

// CachedChapterView 是已缓存章节的明细行。
type CachedChapterView struct {
	Index     int       `json:"index"`
	Title     string    `json:"title"`
	Size      int64     `json:"size"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// CacheBookStatus 是单本书的缓存概况，供详情页/阅读器展示。
type CacheBookStatus struct {
	BookID         int64     `json:"bookId"`
	CachedChapters int       `json:"cachedChapters"`
	TotalChapters  int       `json:"totalChapters"`
	Size           int64     `json:"size"`
	Job            *CacheJob `json:"job"`
}

// CacheStats 是全局缓存统计。
type CacheStats struct {
	Books    int   `json:"books"`
	Chapters int   `json:"chapters"`
	Size     int64 `json:"size"`
	Running  int   `json:"running"` // 正在运行的缓存任务数
}
