package webbook

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/legado/legado-go/pkg/js"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/rule"
	"github.com/legado/legado-go/pkg/urlx"
	"github.com/legado/legado-go/pkg/util"
)

var (
	nameRegex   = regexp.MustCompile(`\s+作\s*者.*|\s+\S+\s+著`)
	authorRegex = regexp.MustCompile(`^\s*作\s*者[:：\s]+|\s+著`)
)

// FormatBookName 书名清洗（对齐 BookHelp.formatBookName）
func FormatBookName(s string) string {
	s = strings.TrimSpace(s)
	return nameRegex.ReplaceAllString(s, "")
}

// FormatBookAuthor 作者清洗（对齐 BookHelp.formatBookAuthor）
func FormatBookAuthor(s string) string {
	s = strings.TrimSpace(s)
	return authorRegex.ReplaceAllString(s, "")
}

// WordCountFormat 字数格式化
func WordCountFormat(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	return s
}

// newRule 创建绑定书源与书籍的规则引擎
func newRule(src *model.BookSource, book *model.Book, rd *model.RuleData) *rule.AnalyzeRule {
	return rule.New(src).SetBook(book).SetRuleData(rd)
}

// fetch 按 URL 规则取回内容，并执行登录检测 JS
func fetch(src *model.BookSource, mUrl, baseUrl string, book *model.Book, chapter *model.BookChapter, page *int, key string) (*urlx.AnalyzeUrl, string, string, error) {
	au := urlx.New(urlx.Options{
		Url:     mUrl,
		Key:     key,
		Page:    page,
		BaseUrl: baseUrl,
		Source:  src,
		Book:    book,
		Chapter: chapter,
	})
	resp, err := au.GetStrResponse()
	if err != nil {
		return au, "", "", err
	}
	body := resp.Body
	// 登录检测 JS：返回新的 body 或 StrResponse
	if src.LoginCheckJs != "" {
		if v := au.EvalCheckJs(src.LoginCheckJs, resp); v != "" {
			body = v
		}
	}
	return au, body, resp.URL, nil
}

// SearchBook 搜索书籍
func SearchBook(src *model.BookSource, key string, page int) ([]*model.SearchBook, error) {
	if strings.TrimSpace(src.SearchUrl) == "" {
		hint := ""
		if len(src.GetExploreKinds()) > 0 {
			hint = "；该源有发现地址，可改用 explore"
		}
		return nil, fmt.Errorf("书源「%s」没有 searchUrl（纯发现源）%s", src.BookSourceName, hint)
	}
	p := page
	if p <= 0 {
		p = 1
	}
	rd := model.NewRuleData()
	au, body, finalURL, err := fetch(src, src.SearchUrl, src.BookSourceUrl, nil, nil, &p, key)
	if err != nil {
		return nil, err
	}
	return analyzeBookList(src, rd, au, finalURL, body, true, false)
}

// ExploreBook 发现书籍
func ExploreBook(src *model.BookSource, url string, page int) ([]*model.SearchBook, error) {
	// 未指定地址时用 exploreUrl 的第一个分类
	if strings.TrimSpace(url) == "" {
		if kinds := src.GetExploreKinds(); len(kinds) > 0 {
			url = kinds[0].Url
		}
	}
	if strings.TrimSpace(url) == "" {
		return nil, fmt.Errorf("发现地址为空，且书源没有配置 exploreUrl")
	}
	p := page
	if p <= 0 {
		p = 1
	}
	rd := model.NewRuleData()
	au, body, finalURL, err := fetch(src, url, src.BookSourceUrl, nil, nil, &p, "")
	if err != nil {
		return nil, err
	}
	return analyzeBookList(src, rd, au, finalURL, body, false, false)
}

// GetBookInfo 获取书籍详情
func GetBookInfo(src *model.BookSource, book *model.Book) error {
	if book.InfoHtml != "" {
		return analyzeBookInfo(src, book, book.BookUrl, book.BookUrl, book.InfoHtml)
	}
	au, body, finalURL, err := fetch(src, book.BookUrl, src.BookSourceUrl, book, nil, nil, "")
	if err != nil {
		return err
	}
	_ = au
	return analyzeBookInfo(src, book, book.BookUrl, finalURL, body)
}

// GetChapterList 获取目录
func GetChapterList(src *model.BookSource, book *model.Book, runPreUpdateJs bool) ([]*model.BookChapter, error) {
	if runPreUpdateJs {
		_ = RunPreUpdateJs(src, book)
	}
	if book.BookUrl == book.TocUrl && book.TocHtml != "" {
		return analyzeChapterList(src, book, book.TocUrl, book.TocUrl, book.TocHtml)
	}
	au, body, finalURL, err := fetch(src, book.TocUrl, book.BookUrl, book, nil, nil, "")
	if err != nil {
		return nil, err
	}
	_ = au
	return analyzeChapterList(src, book, book.TocUrl, finalURL, body)
}

// RunPreUpdateJs 执行目录预更新 JS
func RunPreUpdateJs(src *model.BookSource, book *model.Book) error {
	preUpdateJs := src.GetTocRule().PreUpdateJs
	if strings.TrimSpace(preUpdateJs) == "" {
		return nil
	}
	ar := rule.New(src).SetBook(book)
	ar.SetContent("")
	ar.EvalJS(preUpdateJs)
	return nil
}

// GetContent 获取章节正文
func GetContent(src *model.BookSource, book *model.Book, chapter *model.BookChapter, nextChapterUrl string) (string, error) {
	contentRule := src.GetContentRule()
	if contentRule.Content == "" {
		return chapter.Url, nil
	}
	if chapter.IsVolume && strings.HasPrefix(chapter.Url, chapter.Title) {
		return chapter.Tag, nil
	}
	if chapter.Url == book.BookUrl && book.TocHtml != "" {
		return analyzeContent(src, book, chapter, chapter.GetAbsoluteURL(), chapter.GetAbsoluteURL(), book.TocHtml, nextChapterUrl)
	}
	base := book.TocUrl
	if base == "" {
		base = book.BookUrl
	}
	au := urlx.New(urlx.Options{
		Url:     chapter.GetAbsoluteURL(),
		BaseUrl: base,
		Source:  src,
		Book:    book,
		Chapter: chapter,
	})
	resp, err := au.GetStrResponse()
	if err != nil {
		return "", err
	}
	body := resp.Body
	if src.LoginCheckJs != "" {
		if v := au.EvalCheckJs(src.LoginCheckJs, resp); v != "" {
			body = v
		}
	}
	return analyzeContent(src, book, chapter, chapter.GetAbsoluteURL(), resp.URL, body, nextChapterUrl)
}

// —— 书籍列表 ——

type listRule interface {
	GetBookList() string
	GetName() string
	GetAuthor() string
	GetIntro() string
	GetKind() string
	GetLastChapter() string
	GetBookUrl() string
	GetCoverUrl() string
	GetWordCount() string
}

func analyzeBookList(src *model.BookSource, rd *model.RuleData, au *urlx.AnalyzeUrl, baseUrl, body string, isSearch, isRedirect bool) ([]*model.SearchBook, error) {
	bookList := make([]*model.SearchBook, 0, 16)
	if body == "" {
		return nil, fmt.Errorf("获取网页内容失败: %s", au.RuleUrl)
	}
	ar := newRule(src, nil, rd)
	ar.SetContent(body, baseUrl)
	ar.SetRedirectUrl(baseUrl)

	// 详情页直连判定
	if isSearch && src.BookUrlPattern != "" {
		if matched, err := regexp.MatchString(src.BookUrlPattern, baseUrl); err == nil && matched {
			if sb := getInfoItem(src, ar, au, body, baseUrl, rd.ToJSON(), isRedirect); sb != nil {
				sb.InfoHtml = body
				bookList = append(bookList, sb)
			}
			return bookList, nil
		}
	}

	var lr listRule = src.GetSearchRule()
	if !isSearch {
		if src.GetExploreRule().BookList != "" {
			lr = src.GetExploreRule()
		}
	}
	ruleList := lr.GetBookList()
	reverse := false
	if strings.HasPrefix(ruleList, "-") {
		reverse = true
		ruleList = ruleList[1:]
	}
	if strings.HasPrefix(ruleList, "+") {
		ruleList = ruleList[1:]
	}

	collections := ar.GetElements(ruleList)
	if len(collections) == 0 && src.BookUrlPattern == "" {
		if sb := getInfoItem(src, ar, au, body, baseUrl, rd.ToJSON(), isRedirect); sb != nil {
			sb.InfoHtml = body
			bookList = append(bookList, sb)
		}
		return bookList, nil
	}

	ruleName := ar.SplitSourceRule(lr.GetName())
	ruleBookUrl := ar.SplitSourceRule(lr.GetBookUrl())
	ruleAuthor := ar.SplitSourceRule(lr.GetAuthor())
	ruleCover := ar.SplitSourceRule(lr.GetCoverUrl())
	ruleIntro := ar.SplitSourceRule(lr.GetIntro())
	ruleKind := ar.SplitSourceRule(lr.GetKind())
	ruleLast := ar.SplitSourceRule(lr.GetLastChapter())
	ruleWords := ar.SplitSourceRule(lr.GetWordCount())

	for _, item := range collections {
		sb := getSearchItem(src, ar, item, baseUrl, rd.ToJSON(),
			ruleName, ruleBookUrl, ruleAuthor, ruleCover, ruleIntro, ruleKind, ruleLast, ruleWords)
		if sb == nil {
			continue
		}
		if baseUrl == sb.BookUrl {
			sb.InfoHtml = body
		}
		bookList = append(bookList, sb)
	}
	// 去重
	seen := map[string]bool{}
	unique := make([]*model.SearchBook, 0, len(bookList))
	for _, b := range bookList {
		k := b.Name + "\x00" + b.Author + "\x00" + b.BookUrl
		if seen[k] {
			continue
		}
		seen[k] = true
		unique = append(unique, b)
	}
	if reverse {
		for i, j := 0, len(unique)-1; i < j; i, j = i+1, j-1 {
			unique[i], unique[j] = unique[j], unique[i]
		}
	}
	return unique, nil
}

func getInfoItem(src *model.BookSource, ar *rule.AnalyzeRule, au *urlx.AnalyzeUrl, body, baseUrl, variable string, isRedirect bool) *model.SearchBook {
	book := model.NewBook()
	if variable != "" {
		book.LoadJSON(variable)
	}
	if isRedirect {
		book.BookUrl = baseUrl
	} else {
		book.BookUrl = util.GetAbsoluteURL(au.Url, au.RuleUrl)
	}
	book.Origin = src.BookSourceUrl
	book.OriginName = src.BookSourceName
	book.Type = src.GetBookType()
	ar.SetBook(book)
	if err := analyzeBookInfoWithRule(src, book, body, ar, baseUrl, baseUrl, false); err != nil {
		return nil
	}
	if strings.TrimSpace(book.Name) == "" {
		return nil
	}
	sb := &model.SearchBook{VariableHolder: book.VariableHolder}
	sb.Name = book.Name
	sb.Author = book.Author
	sb.BookUrl = book.BookUrl
	sb.Origin = book.Origin
	sb.OriginName = book.OriginName
	sb.Type = book.Type
	sb.Kind = book.Kind
	sb.WordCount = book.WordCount
	sb.Intro = book.Intro
	sb.CoverUrl = book.CoverUrl
	sb.LatestChapterTitle = book.LatestChapterTitle
	return sb
}

func getSearchItem(src *model.BookSource, ar *rule.AnalyzeRule, item any, baseUrl, variable string,
	ruleName, ruleBookUrl, ruleAuthor, ruleCover, ruleIntro, ruleKind, ruleLast, ruleWords []*rule.SourceRule) *model.SearchBook {
	sb := model.NewSearchBook()
	if variable != "" {
		sb.LoadJSON(variable)
	}
	sb.Type = src.GetBookType()
	sb.Origin = src.BookSourceUrl
	sb.OriginName = src.BookSourceName
	sb.OriginOrder = src.CustomOrder
	ar.SetContent(item)
	sb.Name = FormatBookName(ar.GetString(ruleName))
	if sb.Name == "" {
		return nil
	}
	sb.Author = FormatBookAuthor(ar.GetString(ruleAuthor))
	if kl := ar.GetStringList(ruleKind); len(kl) > 0 {
		sb.Kind = strings.Join(kl, ",")
	}
	sb.WordCount = WordCountFormat(ar.GetString(ruleWords))
	sb.LatestChapterTitle = ar.GetString(ruleLast)
	sb.Intro = util.HtmlFormat(ar.GetString(ruleIntro))
	if cu := ar.GetString(ruleCover); cu != "" {
		sb.CoverUrl = util.GetAbsoluteURL(baseUrl, cu)
	}
	sb.BookUrl = ar.GetString(ruleBookUrl, true)
	if sb.BookUrl == "" {
		sb.BookUrl = baseUrl
	}
	return sb
}

// —— 书籍详情 ——

func analyzeBookInfo(src *model.BookSource, book *model.Book, baseUrl, redirectUrl, body string) error {
	ar := newRule(src, book, nil)
	ar.SetContent(body, baseUrl)
	ar.SetRedirectUrl(redirectUrl)
	return analyzeBookInfoWithRule(src, book, body, ar, baseUrl, redirectUrl, true)
}

func analyzeBookInfoWithRule(src *model.BookSource, book *model.Book, body string, ar *rule.AnalyzeRule, baseUrl, redirectUrl string, canReName bool) error {
	if body == "" {
		return fmt.Errorf("获取书籍详情内容失败: %s", baseUrl)
	}
	infoRule := src.GetBookInfoRule()
	if infoRule.Init != "" {
		if el := ar.GetElement(infoRule.Init); el != nil {
			ar.SetContent(el)
		}
	}
	mCanReName := canReName && infoRule.CanReName != ""
	if n := FormatBookName(ar.GetString(infoRule.Name)); n != "" && (mCanReName || book.Name == "") {
		book.Name = n
	}
	if a := FormatBookAuthor(ar.GetString(infoRule.Author)); a != "" && (mCanReName || book.Author == "") {
		book.Author = a
	}
	if kl := ar.GetStringList(infoRule.Kind); len(kl) > 0 {
		book.Kind = strings.Join(kl, ",")
	}
	if w := WordCountFormat(ar.GetString(infoRule.WordCount)); w != "" {
		book.WordCount = w
	}
	if l := ar.GetString(infoRule.LastChapter); l != "" {
		book.LatestChapterTitle = l
	}
	if i := util.HtmlFormat(ar.GetString(infoRule.Intro)); i != "" {
		book.Intro = i
	}
	if c := ar.GetString(infoRule.CoverUrl); c != "" {
		book.CoverUrl = util.GetAbsoluteURL(redirectUrl, c)
	}
	if !book.IsWebFile() {
		book.TocUrl = ar.GetString(infoRule.TocUrl, true)
		if book.TocUrl == "" {
			book.TocUrl = baseUrl
		}
		if book.TocUrl == baseUrl {
			book.TocHtml = body
		}
	} else {
		urls := ar.GetStringList(infoRule.DownloadUrls, true)
		if len(urls) == 0 {
			return fmt.Errorf("下载链接为空")
		}
		book.DownloadUrls = urls
	}
	return nil
}

// —— 目录 ——

func analyzeChapterList(src *model.BookSource, book *model.Book, baseUrl, redirectUrl, body string) ([]*model.BookChapter, error) {
	if body == "" {
		return nil, fmt.Errorf("获取目录内容失败: %s", baseUrl)
	}
	tocRule := src.GetTocRule()
	listRule := tocRule.ChapterList
	reverse := false
	if strings.HasPrefix(listRule, "-") {
		reverse = true
		listRule = listRule[1:]
	}
	if strings.HasPrefix(listRule, "+") {
		listRule = listRule[1:]
	}
	chapters, nextUrls := parseChapterPage(src, book, baseUrl, redirectUrl, body, tocRule, listRule, true)
	// 翻页
	visited := map[string]bool{redirectUrl: true}
	for len(nextUrls) == 1 && nextUrls[0] != "" && !visited[nextUrls[0]] {
		next := nextUrls[0]
		visited[next] = true
		au := urlx.New(urlx.Options{Url: next, Source: src, Book: book})
		resp, err := au.GetStrResponse()
		if err != nil || resp.Body == "" {
			break
		}
		more, nu := parseChapterPage(src, book, next, next, resp.Body, tocRule, listRule, false)
		chapters = append(chapters, more...)
		nextUrls = nu
		if len(nu) == 0 {
			break
		}
	}
	if len(chapters) == 0 {
		return nil, fmt.Errorf("章节列表为空")
	}
	if !reverse {
		reverseSlice(chapters)
	}
	// 去重
	seen := map[string]bool{}
	unique := make([]*model.BookChapter, 0, len(chapters))
	for _, c := range chapters {
		k := c.Title + "\x00" + c.Url
		if seen[k] {
			continue
		}
		seen[k] = true
		unique = append(unique, c)
	}
	if !book.GetReverseToc() {
		reverseSlice(unique)
	}
	for i, c := range unique {
		c.Index = i
	}
	// formatJs
	if tocRule.FormatJs != "" {
		for i, c := range unique {
			v, err := js.DefaultEngine().Eval(tocRule.FormatJs, &js.Bindings{
				Source:  src,
				Book:    book,
				Chapter: c,
				Extra:   map[string]any{"index": i + 1, "gInt": 0},
			})
			if err == nil && v != nil {
				if s := fmt.Sprint(v); s != "" {
					c.Title = s
				}
			}
		}
	}
	book.TotalChapterNum = len(unique)
	if len(unique) > 0 {
		book.LatestChapterTitle = unique[len(unique)-1].Title
		book.DurChapterTitle = unique[minInt(book.DurChapterIndex, len(unique)-1)].Title
	}
	return unique, nil
}

func parseChapterPage(src *model.BookSource, book *model.Book, baseUrl, redirectUrl, body string, tocRule *model.TocRule, listRule string, getNext bool) ([]*model.BookChapter, []string) {
	ar := newRule(src, book, nil)
	ar.SetContent(body, baseUrl)
	ar.SetRedirectUrl(redirectUrl)
	elements := ar.GetElements(listRule)
	nextUrls := []string{}
	if getNext && tocRule.NextTocUrl != "" {
		if l := ar.GetStringList(tocRule.NextTocUrl, true); l != nil {
			for _, u := range l {
				if u != redirectUrl {
					nextUrls = append(nextUrls, u)
				}
			}
		}
	}
	chapters := make([]*model.BookChapter, 0, len(elements))
	if len(elements) == 0 {
		return chapters, nextUrls
	}
	nameRule := ar.SplitSourceRule(tocRule.ChapterName)
	urlRule := ar.SplitSourceRule(tocRule.ChapterUrl)
	vipRule := ar.SplitSourceRule(tocRule.IsVip)
	payRule := ar.SplitSourceRule(tocRule.IsPay)
	upRule := ar.SplitSourceRule(tocRule.UpdateTime)
	volRule := ar.SplitSourceRule(tocRule.IsVolume)
	for index, item := range elements {
		ar.SetContent(item)
		ch := model.NewBookChapter(book.BookUrl)
		ch.BaseUrl = redirectUrl
		ar.SetChapter(ch)
		ch.Title = ar.GetString(nameRule)
		ch.Url = ar.GetString(urlRule)
		ch.Tag = ar.GetString(upRule)
		if isTrue(ar.GetString(volRule)) {
			ch.IsVolume = true
		}
		if ch.Url == "" {
			if ch.IsVolume {
				ch.Url = ch.Title + fmt.Sprint(index)
			} else {
				ch.Url = baseUrl
			}
		}
		if ch.Title == "" {
			continue
		}
		if isTrue(ar.GetString(vipRule)) {
			ch.IsVip = true
		}
		if isTrue(ar.GetString(payRule)) {
			ch.IsPay = true
		}
		chapters = append(chapters, ch)
	}
	return chapters, nextUrls
}

// —— 正文 ——

func analyzeContent(src *model.BookSource, book *model.Book, chapter *model.BookChapter, baseUrl, redirectUrl, body, nextChapterUrl string) (string, error) {
	if body == "" {
		return "", fmt.Errorf("获取正文内容失败: %s", baseUrl)
	}
	contentRule := src.GetContentRule()
	parts := []string{}
	nextUrlList := []string{redirectUrl}
	content, nextUrls := parseContent(src, book, chapter, baseUrl, redirectUrl, body, nextChapterUrl, true)
	parts = append(parts, content)
	if len(nextUrls) == 1 {
		next := nextUrls[0]
		for next != "" && !contains(nextUrlList, next) {
			if nextChapterUrl != "" &&
				util.GetAbsoluteURL(redirectUrl, next) == util.GetAbsoluteURL(redirectUrl, nextChapterUrl) {
				break
			}
			nextUrlList = append(nextUrlList, next)
			au := urlx.New(urlx.Options{Url: next, Source: src, Book: book, Chapter: chapter})
			resp, err := au.GetStrResponse()
			if err != nil || resp.Body == "" {
				break
			}
			c, nu := parseContent(src, book, chapter, next, resp.URL, resp.Body, nextChapterUrl, true)
			parts = append(parts, c)
			if len(nu) == 0 {
				break
			}
			next = nu[0]
		}
	}
	contentStr := strings.Join(parts, "\n")
	if contentRule.ReplaceRegex != "" {
		ar := newRule(src, book, nil)
		ar.SetContent(contentStr)
		ar.SetChapter(chapter)
		lines := strings.Split(contentStr, "\n")
		var sb strings.Builder
		for i, l := range lines {
			if i > 0 {
				sb.WriteString("\n")
			}
			sb.WriteString("\u3000\u3000" + strings.TrimSpace(l))
		}
		contentStr = ar.GetString(contentRule.ReplaceRegex)
		if contentStr == "" {
			contentStr = sb.String()
		}
	}
	if !chapter.IsVolume && strings.TrimSpace(contentStr) == "" {
		return "", fmt.Errorf("内容为空")
	}
	return contentStr, nil
}

func parseContent(src *model.BookSource, book *model.Book, chapter *model.BookChapter, baseUrl, redirectUrl, body, nextChapterUrl string, getNext bool) (string, []string) {
	ar := newRule(src, book, nil)
	ar.SetContent(body, baseUrl)
	ar.SetRedirectUrl(redirectUrl)
	ar.SetChapter(chapter)
	ar.SetNextChapterUrl(nextChapterUrl)
	content := ar.GetStringUnescape(src.GetContentRule().Content, false)
	content = util.FormatKeepImg(content, redirectUrl)
	if strings.Contains(content, "&") {
		content = util.UnescapeHtml4(content)
	}
	nextUrls := []string{}
	if getNext {
		if nr := src.GetContentRule().NextContentUrl; nr != "" {
			if l := ar.GetStringList(nr, true); l != nil {
				nextUrls = append(nextUrls, l...)
			}
		}
	}
	return content, nextUrls
}

// —— 工具 ——

func reverseSlice(a []*model.BookChapter) {
	for i, j := 0, len(a)-1; i < j; i, j = i+1, j-1 {
		a[i], a[j] = a[j], a[i]
	}
}

func contains(a []string, s string) bool {
	for _, x := range a {
		if x == s {
			return true
		}
	}
	return false
}

func isTrue(s string) bool {
	t := strings.ToLower(strings.TrimSpace(s))
	return t == "true" || t == "1" || t == "yes"
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
