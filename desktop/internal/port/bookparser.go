package port

import (
	"context"
	"io"

	"github.com/legado/desktop/internal/domain"
)

// ParsedBook 是本地书籍解析器的输出，描述一本书的结构与内容入口。
type ParsedBook struct {
	// Chapters 是按阅读顺序排列的章节列表。
	Chapters []*domain.BookChapter
	// Meta 中的字段用于补全/校验书籍信息。
	Meta BookMeta
	// Cover 是解析得到的封面图像；无封面时为 nil。调用方负责关闭。
	Cover io.ReadCloser
	// CoverExt 是封面文件的扩展名（含前导点，如 ".jpg"）。
	// 用于落盘时保留正确扩展名，使 asset server 能返回正确的 MIME。
	CoverExt string
}

// BookMeta 是解析器从文件中提取的元数据。
type BookMeta struct {
	Title  string
	Author string
	Intro  string
}

// ChapterContent 是单个章节的渲染结果。
type ChapterContent struct {
	// Title 是章节标题。
	Title string
	// HTML 是待渲染的正文（已做清洗，可直接交给 WebView）。
	HTML string
	// Images 是漫画/图片类章节的图片地址列表；文本章节为空。
	// 元素既可以是 http(s) 外链，也可以是由 ResourceServer 提供的本地地址。
	Images []string
}

// LocalBookParser 解析本地书籍文件。
//
// 每种格式一个实现（epub / txt / pdf / comic），由 LocalBookParserRegistry 按格式分发。
type LocalBookParser interface {
	// Format 返回本解析器支持的格式。
	Format() domain.BookFormat
	// Parse 解析文件，抽取元数据、目录与章节结构。
	// 正文不在此时读取，避免大文件一次性载入内存。
	Parse(ctx context.Context, path string) (*ParsedBook, error)
	// Content 按章节定位读取正文。
	Content(ctx context.Context, path string, chapter *domain.BookChapter) (*ChapterContent, error)
}

// LocalBookParserRegistry 按格式查找解析器。
type LocalBookParserRegistry interface {
	// Resolve 返回能处理该格式的解析器；无匹配时返回 domain.ErrUnsupportedFormat。
	Resolve(f domain.BookFormat) (LocalBookParser, error)
}

// BookExporter 将书籍导出为指定格式的文件。
type BookExporter interface {
	// Format 返回导出格式。
	Format() domain.BookFormat
	// Extension 返回导出文件的扩展名（含前导点）。
	Extension() string
	// Export 将给定书籍导出到 w。
	Export(ctx context.Context, w io.Writer, b *domain.Book, chapters []*domain.BookChapter, fetch func(*domain.BookChapter) (*ChapterContent, error)) error
}
