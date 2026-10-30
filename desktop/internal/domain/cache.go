package domain

import "time"

// CachedChapter 是被显式缓存下来的章节内容快照，用于离线阅读。
//
// 与 BookChapter 的区别：BookChapter 是目录条目（标题、地址），
// CachedChapter 是那次抓取得到的正文/图片结果。两者以 (BookID, Index) 关联，
// 并用 URL 记录缓存时的源地址——目录更新导致章节地址变化时，
// 旧缓存会被判为失效，避免把上一版正文当成新章节读出来。
//
// 文本章节把正文存 HTML；漫画章节把图片落到磁盘，Images 存可访问的本地地址。
type CachedChapter struct {
	BookID int64    `json:"bookId"`
	Index  int      `json:"index"`
	Title  string   `json:"title"`
	URL    string   `json:"url"`    // 缓存时该章的源地址，用于识别目录变更
	HTML   string   `json:"html"`   // 文本章节正文
	Images []string `json:"images"` // 漫画章节的本地图片地址
	// Size 是这条缓存占用的字节数（正文长度，或图片文件大小之和）。
	Size      int64     `json:"size"`
	CreatedAt time.Time `json:"createdAt"`
}

// IsComic 报告该缓存是否为图片类章节。
func (c *CachedChapter) IsComic() bool { return len(c.Images) > 0 }

// CacheBookStat 是单本书的缓存聚合统计，用于缓存管理列表。
type CacheBookStat struct {
	BookID    int64     `json:"bookId"`
	Chapters  int       `json:"chapters"` // 已缓存章节数
	Size      int64     `json:"size"`     // 占用字节数
	UpdatedAt time.Time `json:"updatedAt"`
}
