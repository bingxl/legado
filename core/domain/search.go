package domain

// SearchResult 是一次网络搜索/发现命中的书籍条目。
// 它由书源抓取产生，经用户确认后转为书架上的 Book。
type SearchResult struct {
	Name        string `json:"name"`
	Author      string `json:"author"`
	Cover       string `json:"cover"`
	Intro       string `json:"intro"`
	BookURL     string `json:"bookUrl"`     // 详情页 URL，同时作为去重键
	Origin      string `json:"origin"`      // 来源书源 URL
	OriginName  string `json:"originName"`  // 来源书源名称
	LastChapter string `json:"lastChapter"` // 最新章节
	Kind        string `json:"kind"`        // 源站点标注的类型
	// Variable 是书源规则在列表页 @put 出来的变量（JSON 对象串）。
	// 有些书源的目录/正文地址要靠它拼（"…/book/@get:{book}/volumes"），
	// 丢掉就会请求到 book//volumes 这种空参数地址，所以必须一路带到书籍上。
	Variable string `json:"variable,omitempty"`
}

// ToBook 将搜索结果转换为待入库的书籍实体。
// 转换后只填充来源与元数据，章节列表需另行抓取。
func (r *SearchResult) ToBook() *Book {
	return &Book{
		Name:        r.Name,
		Author:      r.Author,
		Intro:       r.Intro,
		CoverURL:    r.Cover,
		Kind:        BookKindWeb,
		Format:      BookFormatUnknown,
		Origin:      r.Origin,
		BookURL:     r.BookURL,
		LastChapter: r.LastChapter,
		Variable:    r.Variable,
	}
}

// WebDAVConfig 保存 WebDAV 服务的连接配置。
// 密码字段在返回给前端时一律置空（见 dto.WebDAVConfigView）。
type WebDAVConfig struct {
	URL      string `json:"url"`
	Username string `json:"username"`
	Password string `json:"password"`
	// RootPath 是应用在该 WebDAV 服务上的工作根目录。
	RootPath string `json:"rootPath"`
	// AutoSync 是否在启动与退出时自动同步。
	AutoSync bool `json:"autoSync"`
}
