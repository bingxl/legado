package bookmark

import "time"

// BookmarkItem 是一条书签。
//
// 字段与 bookmark 表一一对应但不暴露表结构：将来给表加内部列
// （例如同步用的版本号）时，前端契约不用跟着变。
type BookmarkItem struct {
	ID           int64     `json:"id"`
	BookID       int64     `json:"bookId"`
	ChapterIndex int       `json:"chapterIndex"`
	ChapterTitle string    `json:"chapterTitle"`
	ChapterPos   int       `json:"chapterPos"`
	Content      string    `json:"content"`
	Note         string    `json:"note"`
	CreatedAt    time.Time `json:"createdAt"`
}

// RecordItem 是一条阅读记录（流水）。
type RecordItem struct {
	ID           int64     `json:"id"`
	BookID       int64     `json:"bookId"`
	BookName     string    `json:"bookName"`
	ChapterIndex int       `json:"chapterIndex"`
	ChapterTitle string    `json:"chapterTitle"`
	ReadAt       time.Time `json:"readAt"`
}

// RecordStats 是阅读记录的聚合统计，用于「阅读统计」页的头部。
//
// Days 统计的是**有阅读行为的天数**（按本地时区切日），
// 而不是首末时间差：断断续续读了 10 天和连续读 10 天应当都算 10 天。
type RecordStats struct {
	Days    int `json:"days"`
	Books   int `json:"books"`
	Records int `json:"records"`
}

// unixTime 把库里的 INTEGER Unix 秒转为 time.Time。
//
// 统一走 time.Unix 而不是存字符串：时间列参与区间比较（Clear 的 beforeDays）
// 与排序，整数比较比字符串便宜且不受时区格式影响。
func unixTime(sec int64) time.Time { return time.Unix(sec, 0) }
