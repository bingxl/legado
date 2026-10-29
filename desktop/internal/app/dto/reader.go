package dto

import "github.com/legado/desktop/internal/domain"

// ChapterContent 是阅读器渲染单章所需的数据。
//
// HTML 与 Images 二选一：文本类章节用 HTML，漫画类章节用 Images。
// 这样前端无需关心格式差异，只需判断哪个字段非空。
type ChapterContent struct {
	BookID        int64    `json:"bookId"`
	Index         int      `json:"index"`
	Title         string   `json:"title"`
	HTML          string   `json:"html"`
	Images        []string `json:"images"`
	PrevIndex     int      `json:"prevIndex"` // 上一章序号，无则为 -1
	NextIndex     int      `json:"nextIndex"` // 下一章序号，无则为 -1
	TotalChapters int      `json:"totalChapters"`
}

// ReadingPosition 描述一次阅读位置，用于恢复与保存。
type ReadingPosition struct {
	BookID        int64   `json:"bookId"`
	ChapterIndex  int     `json:"chapterIndex"`
	ChapterTitle  string  `json:"chapterTitle"`
	ChapterPos    int     `json:"chapterPos"`
	ScrollPercent float64 `json:"scrollPercent"`
}

// NewReadingPosition 从领域实体转换阅读位置。
func NewReadingPosition(p *domain.ReadingProgress) ReadingPosition {
	if p == nil {
		return ReadingPosition{ChapterIndex: -1}
	}
	return ReadingPosition{
		BookID:        p.BookID,
		ChapterIndex:  p.ChapterIndex,
		ChapterTitle:  p.ChapterTitle,
		ChapterPos:    p.ChapterPos,
		ScrollPercent: p.ScrollPercent,
	}
}
