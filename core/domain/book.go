// Package domain 存放领域实体、值对象与领域错误。
//
// 本包是架构的最内层：只允许依赖 Go 标准库，禁止依赖任何框架、
// 数据库驱动或第三方库。对外（前端、持久化、书源引擎）的类型转换
// 一律由外层（app/dto、adapter）负责，领域实体不得直接外泄。
package domain

import "time"

// BookKind 标识书籍内容的来源类型。
type BookKind string

const (
	// BookKindWeb 来自网络书源的书籍。
	BookKindWeb BookKind = "web"
	// BookKindLocal 从本地文件导入的书籍。
	BookKindLocal BookKind = "local"
)

// BookFormat 标识书籍的正文格式，决定由哪个解析器处理。
type BookFormat string

const (
	BookFormatEPUB  BookFormat = "epub"
	BookFormatTXT   BookFormat = "txt"
	BookFormatPDF   BookFormat = "pdf"
	BookFormatComic BookFormat = "comic"
	// BookFormatAudio 来自 bookSourceType=1 的音频书：章节「正文」是音频地址规则串。
	BookFormatAudio BookFormat = "audio"
	// BookFormatUnknown 用于尚未识别格式（例如网络书在未抓取前）。
	BookFormatUnknown BookFormat = "unknown"
)

// Book.type 位域，取值必须与 Kotlin 原版 constant/BookType.kt 一致：
// 书源 JS 会直接读 `book.type`（`=== 64` 图片、`& 128` 下载站），错位会静默失效。
// domain 不依赖书源引擎，所以这里独立定义一份同值常量。
const (
	BookTypeText  = 1 << 3 // 8
	BookTypeAudio = 1 << 5 // 32
	BookTypeImage = 1 << 6 // 64
)

// String 返回格式的可读名称，用于前端展示。
func (f BookFormat) String() string {
	switch f {
	case BookFormatEPUB:
		return "EPUB"
	case BookFormatTXT:
		return "TXT"
	case BookFormatPDF:
		return "PDF"
	case BookFormatComic:
		return "漫画"
	case BookFormatAudio:
		return "音频"
	default:
		return "未知"
	}
}

// ParseBookFormat 从文件扩展名推断格式，无法识别时返回 BookFormatUnknown。
func ParseBookFormat(ext string) BookFormat {
	switch ext {
	case ".epub":
		return BookFormatEPUB
	case ".txt":
		return BookFormatTXT
	case ".pdf":
		return BookFormatPDF
	case ".cbz", ".zip", ".cbr", ".rar", ".7z":
		return BookFormatComic
	default:
		return BookFormatUnknown
	}
}

// Book 是书架上的一本书，是书架管理与阅读的核心聚合根。
//
// 注意：Book 只承载"这本书是什么、读到哪"的信息，不承载章节列表与正文，
// 后者分别由 BookChapter 与阅读器按需加载。
type Book struct {
	ID         int64      `json:"id"`
	Name       string     `json:"name"`
	Author     string     `json:"author"`
	Intro      string     `json:"intro"`
	CoverURL   string     `json:"coverUrl"`   // 网络封面 URL 或本地封面路径
	Kind       BookKind   `json:"kind"`       // 来源类型
	Format     BookFormat `json:"format"`     // 正文格式
	Type       int        `json:"type"`       // Legado Book.type 位域（音频 32 / 图片 64 / 文本 8）
	Origin     string     `json:"origin"`     // 来源标识：书源 URL，或本地书的 "local"
	OriginName string     `json:"originName"` // 来源书源名称，本地书为空
	BookURL    string     `json:"bookUrl"`    // 网络书详情页 URL；本地书为文件绝对路径
	GroupID    int64      `json:"groupId"`    // 所属分组，0 表示未分组
	Order      int        `json:"order"`      // 分组内排序号，越小越靠前
	// Variable 是书源在列表页 @put 出来的变量（JSON 对象串）。
	// 网络书的目录/正文地址常依赖它，丢失会导致请求参数为空、目录拉不到。
	Variable string `json:"variable,omitempty"`

	TotalChapters int    `json:"totalChapters"` // 章节总数
	LastChapter   string `json:"lastChapter"`   // 最新章节标题（用于书架展示"更新到"）

	DurChapterIndex int    `json:"durChapterIndex"` // 当前阅读章节序号（从 0 开始）
	DurChapterTitle string `json:"durChapterTitle"` // 当前阅读章节标题
	DurChapterPos   int    `json:"durChapterPos"`   // 章节内位置（TXT 字符偏移 / EPUB、PDF 页码 / 音频书为播放毫秒）

	CreatedAt  time.Time `json:"createdAt"`
	UpdatedAt  time.Time `json:"updatedAt"`
	LastReadAt time.Time `json:"lastReadAt"`

	// Previewing 表示这本书只是「试读」：已入库供详情页与阅读器使用，
	// 但不出现在书架列表里（发现/搜索点开书时不会自动入架）。
	//
	// 零值 false 表示正常在架——本地导入、WebDAV、命令行等既有创建路径
	// 都不需要显式设置就保持原语义。
	Previewing bool `json:"previewing"`
}

// IsLocal 报告该书是否为本地导入书籍。
func (b *Book) IsLocal() bool { return b.Kind == BookKindLocal }

// IsComic 报告该书是否为漫画（图片流）类型。
func (b *Book) IsComic() bool { return b.Format == BookFormatComic }

// IsAudio 报告该书是否是音频书（走播放器而不是阅读器）。
//
// Type 是权威来源；Format 是冗余兜底：旧库里 type 列尚未回填时，
// 导入时写下的 format=audio 仍能正确分流。
func (b *Book) IsAudio() bool {
	return b.Type&BookTypeAudio != 0 || b.Format == BookFormatAudio
}

// ReadPercent 返回阅读进度百分比（0~100），章节总数为 0 时返回 0。
func (b *Book) ReadPercent() int {
	if b.TotalChapters <= 0 {
		return 0
	}
	pct := (b.DurChapterIndex + 1) * 100 / b.TotalChapters
	if pct > 100 {
		pct = 100
	}
	return pct
}

// BookGroup 是书架分组，用于对书籍做归类展示。
type BookGroup struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`
	Order   int    `json:"order"`
	Show    bool   `json:"show"`    // 是否在书架中显示
	BuiltIn bool   `json:"builtIn"` // 内置分组不可删除
}

// BookChapter 是一本书的章节条目。
//
// 网络书的章节由书源抓取得到并可缓存；本地书的章节由解析器从文件中提取。
type BookChapter struct {
	ID       int64  `json:"id"`
	BookID   int64  `json:"bookId"`
	Index    int    `json:"index"` // 章节序号，从 0 开始
	Title    string `json:"title"`
	URL      string `json:"url"`      // 网络章节 URL；本地书可为空
	Resource string `json:"resource"` // 本地书的资源定位（EPUB 的 spine id、漫画的图片路径）
	IsVolume bool   `json:"isVolume"` // 是否为分卷标题（非正文）
}

// ReadingProgress 记录一次阅读位置，与 Book 上的 Dur* 字段互为冗余：
// Book 上的字段用于书架列表展示，本实体用于阅读器精确恢复。
type ReadingProgress struct {
	BookID        int64     `json:"bookId"`
	ChapterIndex  int       `json:"chapterIndex"`
	ChapterTitle  string    `json:"chapterTitle"`
	ChapterPos    int       `json:"chapterPos"`    // 章节内位置
	ScrollPercent float64   `json:"scrollPercent"` // 章节内滚动百分比 0~100
	UpdatedAt     time.Time `json:"updatedAt"`
}
