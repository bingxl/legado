// Package dto 定义前后端之间的数据传输对象（契约）。
//
// 存在意义（见 ARCHITECTURE.md R3）：领域实体不得直接暴露给前端。
// 数据库 schema 或领域模型的重构不应波及 UI，DTO 就是这层隔离。
//
// 约定：
//  1. dto 只做数据塑形，不含业务逻辑；
//  2. 每个 DTO 提供 NewXxx 构造函数从领域实体转换；
//  3. 时间字段统一使用 RFC3339 字符串或 *time.Time，避免零值歧义。
package dto

import (
	"time"

	"github.com/legado/desktop/internal/domain"
)

// BookBrief 是书架列表中的书籍摘要，字段精简以满足列表渲染。
type BookBrief struct {
	ID              int64      `json:"id"`
	Name            string     `json:"name"`
	Author          string     `json:"author"`
	Cover           string     `json:"cover"`
	Kind            string     `json:"kind"`
	Format          string     `json:"format"`
	FormatLabel     string     `json:"formatLabel"` // 用于展示的中文格式名
	GroupID         int64      `json:"groupId"`
	TotalChapters   int        `json:"totalChapters"`
	LastChapter     string     `json:"lastChapter"`
	DurChapterIndex int        `json:"durChapterIndex"`
	DurChapterTitle string     `json:"durChapterTitle"`
	Percent         int        `json:"percent"` // 阅读进度 0~100
	LastReadAt      *time.Time `json:"lastReadAt"`
	UpdatedAt       time.Time  `json:"updatedAt"`
}

// NewBookBrief 从领域实体构造书架摘要。
func NewBookBrief(b *domain.Book) BookBrief {
	var lastRead *time.Time
	if !b.LastReadAt.IsZero() {
		t := b.LastReadAt
		lastRead = &t
	}
	return BookBrief{
		ID:              b.ID,
		Name:            b.Name,
		Author:          b.Author,
		Cover:           b.CoverURL,
		Kind:            string(b.Kind),
		Format:          string(b.Format),
		FormatLabel:     b.Format.String(),
		GroupID:         b.GroupID,
		TotalChapters:   b.TotalChapters,
		LastChapter:     b.LastChapter,
		DurChapterIndex: b.DurChapterIndex,
		DurChapterTitle: b.DurChapterTitle,
		Percent:         b.ReadPercent(),
		LastReadAt:      lastRead,
		UpdatedAt:       b.UpdatedAt,
	}
}

// NewBookBriefs 批量转换书籍摘要。
func NewBookBriefs(books []*domain.Book) []BookBrief {
	out := make([]BookBrief, 0, len(books))
	for _, b := range books {
		out = append(out, NewBookBrief(b))
	}
	return out
}

// BookDetail 是书籍详情，在 BookBrief 基础上补充来源信息。
type BookDetail struct {
	BookBrief
	Intro   string `json:"intro"`
	Origin  string `json:"origin"`
	BookURL string `json:"bookUrl"`
}

// NewBookDetail 从领域实体构造书籍详情。
func NewBookDetail(b *domain.Book) BookDetail {
	return BookDetail{
		BookBrief: NewBookBrief(b),
		Intro:     b.Intro,
		Origin:    b.Origin,
		BookURL:   b.BookURL,
	}
}

// BookGroupView 是书架分组视图。
type BookGroupView struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`
	Order   int    `json:"order"`
	Show    bool   `json:"show"`
	BuiltIn bool   `json:"builtIn"`
}

// NewBookGroupView 转换分组视图。
func NewBookGroupView(g *domain.BookGroup) BookGroupView {
	if g == nil {
		return BookGroupView{}
	}
	return BookGroupView{
		ID:      g.ID,
		Name:    g.Name,
		Order:   g.Order,
		Show:    g.Show,
		BuiltIn: g.BuiltIn,
	}
}

// NewBookGroupViews 批量转换分组视图。
func NewBookGroupViews(groups []*domain.BookGroup) []BookGroupView {
	out := make([]BookGroupView, 0, len(groups))
	for _, g := range groups {
		out = append(out, NewBookGroupView(g))
	}
	return out
}

// ChapterItem 是目录中的一章。
type ChapterItem struct {
	Index    int    `json:"index"`
	Title    string `json:"title"`
	URL      string `json:"url"`
	IsVolume bool   `json:"isVolume"`
}

// NewChapterItem 转换章节条目。
func NewChapterItem(c *domain.BookChapter) ChapterItem {
	if c == nil {
		return ChapterItem{}
	}
	return ChapterItem{
		Index:    c.Index,
		Title:    c.Title,
		URL:      c.URL,
		IsVolume: c.IsVolume,
	}
}

// NewChapterItems 批量转换章节条目。
func NewChapterItems(chapters []*domain.BookChapter) []ChapterItem {
	out := make([]ChapterItem, 0, len(chapters))
	for _, c := range chapters {
		out = append(out, NewChapterItem(c))
	}
	return out
}
