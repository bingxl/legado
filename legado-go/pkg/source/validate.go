package source

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/dop251/goja"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/webbook"
)

// Level 问题级别
type Level string

const (
	LevelError Level = "ERROR"
	LevelWarn  Level = "WARN"
	LevelInfo  Level = "INFO"
)

// Issue 校验问题
type Issue struct {
	Level   Level
	Field   string
	Message string
}

func (i Issue) String() string {
	return fmt.Sprintf("[%s] %s: %s", i.Level, i.Field, i.Message)
}

// Result 单个书源的校验结果
type Result struct {
	Source *model.BookSource
	File   string
	Issues []Issue
}

// OK 是否无错误
func (r *Result) OK() bool {
	for _, i := range r.Issues {
		if i.Level == LevelError {
			return false
		}
	}
	return true
}

var (
	jsBlockRe = regexp.MustCompile(`(?is)<js>([\s\S]*?)</js>|@js:([\s\S]*)`)
	getRe     = regexp.MustCompile(`(?i)@get:\{[^}]+?\}`)
	putRe     = regexp.MustCompile(`(?i)@put:(\{[^}]+?\})`)
)

// Validate 离线校验书源语法
func Validate(src *model.BookSource) *Result {
	r := &Result{Source: src}
	add := func(lv Level, field, msg string) {
		r.Issues = append(r.Issues, Issue{lv, field, msg})
	}

	if src == nil {
		add(LevelError, "bookSource", "书源为空")
		return r
	}
	// 基础字段
	if strings.TrimSpace(src.BookSourceUrl) == "" {
		add(LevelError, "bookSourceUrl", "不能为空")
	} else if !strings.HasPrefix(strings.ToLower(src.BookSourceUrl), "http") {
		add(LevelError, "bookSourceUrl", "必须以 http/https 开头")
	}
	if strings.TrimSpace(src.BookSourceName) == "" {
		add(LevelWarn, "bookSourceName", "书源名称为空")
	}
	if strings.TrimSpace(src.SearchUrl) == "" {
		if strings.TrimSpace(src.ExploreUrl) == "" {
			add(LevelError, "searchUrl", "搜索地址与发现地址均为空，书源不可用")
		} else {
			add(LevelWarn, "searchUrl", "搜索地址为空（仅有发现，属发现型书源）")
		}
	}

	// 规则完整性
	sr := src.GetSearchRule()
	if strings.TrimSpace(sr.BookList) == "" && strings.TrimSpace(src.BookUrlPattern) == "" {
		add(LevelWarn, "ruleSearch.bookList", "为空且无 bookUrlPattern，可能无法解析列表")
	}
	if strings.TrimSpace(sr.Name) == "" {
		add(LevelWarn, "ruleSearch.name", "为空，无法获取书名")
	}
	if strings.TrimSpace(sr.BookUrl) == "" {
		add(LevelWarn, "ruleSearch.bookUrl", "为空，无法获取详情页链接")
	}
	tr := src.GetTocRule()
	if strings.TrimSpace(tr.ChapterList) == "" {
		add(LevelWarn, "ruleToc.chapterList", "为空，可能无法解析目录")
	}
	if strings.TrimSpace(tr.ChapterName) == "" {
		add(LevelWarn, "ruleToc.chapterName", "为空，无法获取章节名")
	}
	cr := src.GetContentRule()
	if strings.TrimSpace(cr.Content) == "" {
		add(LevelWarn, "ruleContent.content", "为空，无法获取正文")
	}

	// 逐条规则语法检查
	fields := map[string]string{
		"searchUrl":              src.SearchUrl,
		"exploreUrl":             src.ExploreUrl,
		"header":                 src.Header,
		"loginUrl":               src.LoginUrl,
		"loginCheckJs":           src.LoginCheckJs,
		"coverDecodeJs":          src.CoverDecodeJs,
		"search.checkKeyWord":    sr.CheckKeyWord,
		"search.bookList":        sr.BookList,
		"search.name":            sr.Name,
		"search.author":          sr.Author,
		"search.intro":           sr.Intro,
		"search.kind":            sr.Kind,
		"search.lastChapter":     sr.LastChapter,
		"search.bookUrl":         sr.BookUrl,
		"search.coverUrl":        sr.CoverUrl,
		"search.wordCount":       sr.WordCount,
		"toc.preUpdateJs":        tr.PreUpdateJs,
		"toc.chapterList":        tr.ChapterList,
		"toc.chapterName":        tr.ChapterName,
		"toc.chapterUrl":         tr.ChapterUrl,
		"toc.formatJs":           tr.FormatJs,
		"toc.nextTocUrl":         tr.NextTocUrl,
		"toc.isVolume":           tr.IsVolume,
		"content.content":        cr.Content,
		"content.nextContentUrl": cr.NextContentUrl,
		"content.replaceRegex":   cr.ReplaceRegex,
		"content.webJs":          cr.WebJs,
	}
	if src.RuleExplore != nil {
		e := src.RuleExplore
		fields["explore.bookList"] = e.BookList
		fields["explore.name"] = e.Name
		fields["explore.bookUrl"] = e.BookUrl
	}
	if src.RuleBookInfo != nil {
		i := src.RuleBookInfo
		fields["info.init"] = i.Init
		fields["info.name"] = i.Name
		fields["info.author"] = i.Author
		fields["info.tocUrl"] = i.TocUrl
		fields["info.coverUrl"] = i.CoverUrl
		fields["info.downloadUrls"] = i.DownloadUrls
	}

	names := make([]string, 0, len(fields))
	for k := range fields {
		names = append(names, k)
	}
	sortStrings(names)
	for _, name := range names {
		for _, is := range checkRule(name, fields[name]) {
			r.Issues = append(r.Issues, is)
		}
	}

	// jsLib 编译检查
	if strings.TrimSpace(src.JsLib) != "" {
		if _, err := goja.Compile("jsLib", src.JsLib, false); err != nil {
			add(LevelError, "jsLib", "JS 语法错误: "+err.Error())
		}
	}
	return r
}

// checkRule 检查单条规则
func checkRule(field, rule string) []Issue {
	var out []Issue
	if strings.TrimSpace(rule) == "" {
		return out
	}
	add := func(lv Level, msg string) {
		out = append(out, Issue{lv, field, msg})
	}
	// @get:{...}
	for _, m := range getRe.FindAllString(rule, -1) {
		if !strings.HasSuffix(m, "}") {
			add(LevelError, "@get:{} 未闭合")
		}
	}
	// @put:{...}
	for _, m := range putRe.FindAllStringSubmatch(rule, -1) {
		if len(m) > 1 && !isJSONObject(m[1]) {
			add(LevelWarn, "@put JSON 格式不规范: "+m[1])
		}
	}
	// <js></js> 配对
	if strings.Contains(strings.ToLower(rule), "<js>") && !strings.Contains(strings.ToLower(rule), "</js>") {
		add(LevelError, "<js> 缺少 </js>")
	}
	// JS 块编译（JS 的括号平衡由编译器保证，故先剥离再检查剩余规则）
	rest := rule
	for _, m := range jsBlockRe.FindAllStringSubmatch(rule, -1) {
		code := ""
		if len(m) > 2 && m[2] != "" {
			code = m[2]
		} else if len(m) > 1 && m[1] != "" {
			code = m[1]
		}
		if m[0] != "" {
			rest = strings.Replace(rest, m[0], "", 1)
		}
		if code == "" {
			continue
		}
		if _, err := goja.Compile(field, code, false); err != nil {
			add(LevelError, "JS 语法错误: "+err.Error())
		}
	}
	// —— 以下检查只看非 JS 部分 ——
	// JS 里出现 "}}"（例如 `}})`、`}});`）非常常见，若拿整条规则去数括号会大量误报。
	if strings.TrimSpace(rest) == "" {
		return out
	}
	// {{ }} 配对
	if !mustachePaired(rest) {
		add(LevelError, "{{ }} 未配对")
	}
	// 括号平衡（排除引号内）
	if !bracketsBalanced(rest) {
		add(LevelWarn, "括号 [] () 未平衡")
	}
	// ## 正则检查
	parts := strings.Split(rest, "##")
	if len(parts) > 4 {
		add(LevelWarn, "## 分隔段超过 4 段，多余的将被忽略")
	}
	if len(parts) >= 2 && strings.TrimSpace(parts[1]) != "" {
		if _, err := regexp.Compile(parts[1]); err != nil {
			add(LevelError, "替换正则不合法: "+err.Error())
		}
	}
	return out
}

// mustachePaired 检查 {{ }} 是否配对（允许嵌套）
func mustachePaired(s string) bool {
	depth := 0
	for i := 0; i < len(s); i++ {
		switch {
		case i+1 < len(s) && s[i] == '{' && s[i+1] == '{':
			depth++
			i++
		case i+1 < len(s) && s[i] == '}' && s[i+1] == '}':
			if depth > 0 {
				depth--
			}
			i++
		}
	}
	return depth == 0
}

func isJSONObject(s string) bool {
	s = strings.TrimSpace(s)
	return strings.HasPrefix(s, "{") && strings.HasSuffix(s, "}")
}

// bracketsBalanced 检查 [] 与 () 是否在引号外平衡
func bracketsBalanced(s string) bool {
	depth := 0
	inS, inD := false, false
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\':
			i++
			continue
		case c == '\'' && !inD:
			inS = !inS
		case c == '"' && !inS:
			inD = !inD
		case inS || inD:
		default:
			if c == '[' || c == '(' {
				depth++
			} else if c == ']' || c == ')' {
				depth--
				if depth < 0 {
					return false
				}
			}
		}
	}
	return depth == 0
}

func sortStrings(a []string) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && a[j] < a[j-1]; j-- {
			a[j], a[j-1] = a[j-1], a[j]
		}
	}
}

// FirstExploreUrl 取 exploreUrl 第一个分类的地址
func FirstExploreUrl(exploreUrl string) string {
	if kinds := (&model.BookSource{ExploreUrl: exploreUrl}).GetExploreKinds(); len(kinds) > 0 {
		return kinds[0].Url
	}
	return ""
}

// CheckItems 在线校验项
type CheckItems struct {
	Search  bool
	Info    bool
	Toc     bool
	Content bool
}

// ValidateOnline 在线校验：实际请求书源各流程
func ValidateOnline(src *model.BookSource, keyword string, items CheckItems) *Result {
	r := Validate(src)
	add := func(lv Level, field, msg string) {
		r.Issues = append(r.Issues, Issue{lv, field, msg})
	}
	if keyword == "" {
		keyword = src.GetCheckKeyword("我的")
	}
	if !items.Search && !items.Info && !items.Toc && !items.Content {
		return r
	}
	var book *model.Book
	if items.Search || items.Info || items.Toc || items.Content {
		// 纯发现源没有 searchUrl，退回第一个发现分类取书
		if strings.TrimSpace(src.SearchUrl) == "" {
			eu := FirstExploreUrl(src.ExploreUrl)
			if eu == "" {
				add(LevelError, "search", "搜索地址与发现地址均为空，无法实测")
				return r
			}
			list, err := webbook.ExploreBook(src, eu, 1)
			if err != nil {
				add(LevelError, "explore", "发现失败: "+err.Error())
				return r
			}
			if len(list) == 0 {
				add(LevelError, "explore", "发现结果为空")
				return r
			}
			add(LevelInfo, "explore", fmt.Sprintf("发现成功，命中 %d 条（搜不到搜索地址，用首个分类实测）", len(list)))
			book = list[0].ToBook()
		} else {
			list, err := webbook.SearchBook(src, keyword, 1)
			if err != nil {
				add(LevelError, "search", "搜索失败: "+err.Error())
				return r
			}
			if len(list) == 0 {
				add(LevelError, "search", "搜索结果为空")
				return r
			}
			add(LevelInfo, "search", fmt.Sprintf("搜索成功，命中 %d 条", len(list)))
			book = list[0].ToBook()
		}
	}
	if items.Info && book != nil {
		if err := webbook.GetBookInfo(src, book); err != nil {
			add(LevelError, "info", "获取详情失败: "+err.Error())
		} else {
			add(LevelInfo, "info", fmt.Sprintf("《%s》作者:%s 目录:%s", book.Name, book.Author, book.TocUrl))
		}
	}
	var chapters []*model.BookChapter
	if items.Toc && book != nil {
		cl, err := webbook.GetChapterList(src, book, false)
		if err != nil {
			add(LevelError, "toc", "获取目录失败: "+err.Error())
			return r
		}
		chapters = cl
		add(LevelInfo, "toc", fmt.Sprintf("目录解析成功，共 %d 章", len(chapters)))
	}
	if items.Content && book != nil && len(chapters) > 0 {
		c, err := webbook.GetContent(src, book, chapters[0], "")
		if err != nil {
			add(LevelError, "content", "获取正文失败: "+err.Error())
		} else {
			preview := c
			if len([]rune(preview)) > 60 {
				preview = string([]rune(preview)[:60])
			}
			add(LevelInfo, "content", fmt.Sprintf("正文解析成功(%d 字)，预览: %s…", len([]rune(c)), strings.ReplaceAll(preview, "\n", " ")))
		}
	}
	return r
}
