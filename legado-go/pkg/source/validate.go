package source

import (
	"fmt"
	"regexp"
	"strings"

	regexp2 "github.com/dlclark/regexp2/v2"
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
	// mustacheRe 匹配 legado 的变量插值 {{...}}，用于在 JS 编译前做占位替换
	mustacheRe = regexp.MustCompile(`(?s)\{\{.*?\}\}`)
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
		// JS 里可以内嵌 legado 的变量插值，例如
		//   ({{$.sid}} != 0) ? "..." : "..."
		// 这些 {{...}} 在交给 JS 引擎前会被 legado 换成字面量，直接编译必然报
		// "Unexpected token {"。统一换成 0 后再编译（数字在表达式与字符串里都合法）。
		code = mustacheRe.ReplaceAllString(code, "0")
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
	// ## 正则检查
	//
	// 书源里的替换正则写的是 **Java 正则**，普遍使用环视（`(?<=`、`(?!`），
	// 而 Go 的 RE2 不支持——直接拿 regexp.Compile 判断会把正常书源判成有错。
	// 因此先用 Go 编译，失败再交给 regexp2（支持环视）兜底。
	parts := strings.Split(rest, "##")
	if len(parts) > 4 {
		add(LevelWarn, "## 分隔段超过 4 段，多余的将被忽略")
	}
	if len(parts) >= 2 && strings.TrimSpace(parts[1]) != "" {
		if err := compileJavaRegex(parts[1]); err != nil {
			add(LevelError, "替换正则不合法: "+err.Error())
		}
	}
	return out
}

// compileJavaRegex 以 Java 正则语义校验表达式是否可用。
//
// 顺序：RE2（快）→ regexp2（支持环视/反向引用等 RE2 缺失的语法）。
func compileJavaRegex(pattern string) error {
	if _, err := regexp.Compile(pattern); err == nil {
		return nil
	}
	if _, err := regexp2.Compile(pattern, regexp2.None); err != nil {
		return err
	}
	return nil
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

func sortStrings(a []string) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && a[j] < a[j-1]; j-- {
			a[j], a[j-1] = a[j-1], a[j]
		}
	}
}

// FirstExploreUrl 取 exploreUrl 第一个分类的地址
func FirstExploreUrl(exploreUrl string) string {
	if kinds := model.ParseExploreKinds(exploreUrl); len(kinds) > 0 {
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
				add(LevelError, "search", fmt.Sprintf("搜索 %q 无结果（可能关键词无匹配，或站点反爬/要求登录）", keyword))
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
		idx, content, err := probeContent(src, book, chapters)
		if err != nil {
			add(LevelError, "content", "获取正文失败: "+err.Error())
		} else {
			preview := content
			if len([]rune(preview)) > 60 {
				preview = string([]rune(preview)[:60])
			}
			if idx > 0 {
				add(LevelWarn, "content", fmt.Sprintf("前 %d 章正文为空，第 %d 章可读", idx, idx+1))
			}
			add(LevelInfo, "content", fmt.Sprintf("正文解析成功(%d 字)，预览: %s…", len([]rune(content)), strings.ReplaceAll(preview, "\n", " ")))
		}
	}
	return r
}

// contentProbeLimit 正文探测最多尝试几章
const contentProbeLimit = 3

// minContentRunes 判定「正文有效」的最小字数
//
// 书源首章经常指向详情页、公告页或空页（例如 ESJ Zone 的「序章」就是详情页），
// 只试第 1 章会把本来可用的书源误判为不可用，因此逐章探测。
// 同时用它挡住「抓回来一两个字符（诸如分隔符、undefined）」的假成功。
const minContentRunes = 50

// probeContent 逐章探测正文，返回首个成功的章节下标（从 0 开始）与内容
func probeContent(src *model.BookSource, book *model.Book, chapters []*model.BookChapter) (int, string, error) {
	n := len(chapters)
	if n > contentProbeLimit {
		n = contentProbeLimit
	}
	var firstErr error
	for i := 0; i < n; i++ {
		c, err := webbook.GetContent(src, book, chapters[i], "")
		if err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("第 %d 章: %w", i+1, err)
			}
			continue
		}
		if got := len([]rune(strings.TrimSpace(c))); got < minContentRunes {
			if firstErr == nil {
				firstErr = fmt.Errorf("第 %d 章正文仅 %d 字", i+1, got)
			}
			continue
		}
		return i, c, nil
	}
	if firstErr == nil {
		firstErr = fmt.Errorf("前 %d 章均无有效正文", n)
	}
	return -1, "", firstErr
}
