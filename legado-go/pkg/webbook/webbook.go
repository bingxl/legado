package webbook

import (
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/legado/legado-go/pkg/debug"
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

func init() {
	// preUpdateJs 里的 java.reGetBook / java.refreshTocUrl 需要回环到详情页抓取，
	// 实现放在这里通过 Hook 反注给 js 包，避免 js ↔ webbook 循环依赖。
	js.Hooks.RefreshTocUrl = func(src *model.BookSource, book *model.Book) error {
		book.TocUrl = ""
		book.TocHtml = ""
		return GetBookInfo(src, book)
	}
	js.Hooks.ReGetBook = func(src *model.BookSource, book *model.Book) error {
		// 对齐 Kotlin：按书名+作者精确搜索一次拿到新详情页地址与变量，
		// 再重新解析详情页（TocUrl 会被重算）。
		if list, err := SearchBook(src, book.Name, 1); err == nil {
			for _, sb := range list {
				if sb.Name != book.Name {
					continue
				}
				if book.Author != "" && sb.Author != book.Author {
					continue
				}
				book.BookUrl = sb.BookUrl
				if v := sb.ToJSON(); v != "" {
					book.LoadJSON(v)
				}
				break
			}
		}
		book.TocUrl = ""
		book.TocHtml = ""
		return GetBookInfo(src, book)
	}
}

// —— 调试打点 ——
// 输出位置与文案对齐 Kotlin 的 model/webBook/*.kt：≡ 提示、┌└ 规则组、◇ 统计。
// 未启用调试时这些函数只付一次原子读的代价。

// logFetched 记录一次成功的网页请求：对应 Kotlin 的
// Debug.log("≡获取成功:$url") + Debug.log(body, state = 10/20/30/40)
func logFetched(state int, ruleUrl, body string) {
	if !debug.Enabled() {
		return
	}
	debug.Log("≡获取成功:" + ruleUrl)
	debug.Body(state, body)
}

// logCount 输出 ◇ 统计行
func logCount(label string, n int) {
	if !debug.Enabled() {
		return
	}
	debug.Log("◇" + label + ":" + strconv.Itoa(n))
}

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
	ar := rule.New(src).SetBook(book)
	if rd != nil {
		ar.SetRuleData(rd)
	}
	return ar
}

// fetched 一次抓取的结果
type fetched struct {
	au         *urlx.AnalyzeUrl
	body       string
	url        string
	isRedirect bool
}

// fetch 按 URL 规则取回内容，并执行登录检测 JS
func fetch(src *model.BookSource, mUrl, baseUrl string, book *model.Book, chapter *model.BookChapter, page *int, key string) (*fetched, error) {
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
		return nil, err
	}
	body := resp.Body
	// 登录检测 JS：返回新的 body 或 StrResponse
	if src.LoginCheckJs != "" {
		if v := au.EvalCheckJs(src.LoginCheckJs, resp); v != "" {
			body = v
		}
	}
	return &fetched{au: au, body: body, url: resp.URL, isRedirect: resp.IsRedirect}, nil
}

// SearchBook 搜索书籍
func SearchBook(src *model.BookSource, key string, page int) ([]*model.SearchBook, error) {
	if strings.TrimSpace(src.SearchUrl) == "" {
		hint := ""
		if len(GetExploreKinds(src)) > 0 {
			hint = "；该源有发现地址，可改用 explore"
		}
		return nil, fmt.Errorf("书源「%s」没有 searchUrl（纯发现源）%s", src.BookSourceName, hint)
	}
	p := page
	if p <= 0 {
		p = 1
	}
	rd := model.NewRuleData()
	f, err := fetch(src, src.SearchUrl, src.BookSourceUrl, nil, nil, &p, key)
	if err != nil {
		return nil, err
	}
	return analyzeBookList(src, rd, f.au, f.url, f.body, true, f.isRedirect)
}

// GetExploreKinds 解析书源的发现分类。
//
// exploreUrl 有两种形态，必须都支持：
//  1. 静态配置：JSON 数组，或 `分类名::地址` 行；
//  2. JS 代码：`@js:{...}` 或 `<js>...</js>`，脚本返回分类配置字符串。
//
// 第 2 种在真实书源里占多数（分类地址要拼签名、时间戳、分区参数），
// 只做静态解析会把整段 JS 按行拆成一堆同名分类——不报错，但全部不可用。
func GetExploreKinds(src *model.BookSource) []model.ExploreKind {
	raw := strings.TrimSpace(src.ExploreUrl)
	if raw == "" {
		return nil
	}
	code, isJS := exploreKindsJS(raw)
	if !isJS {
		return model.ParseExploreKinds(raw)
	}
	v, err := js.DefaultEngine().Eval(code, &js.Bindings{Source: src})
	if err != nil {
		debug.Log("◇发现分类 JS 执行失败: " + err.Error())
		return nil
	}
	return model.ParseExploreKinds(exploreKindsText(v))
}

// firstExploreUrl 取第一个有地址的分类（分组标题的 url 为空）。
// 对齐 legado：分组标题会保留在分类列表里，但选默认地址时要跳过。
func firstExploreUrl(kinds []model.ExploreKind) string {
	for _, k := range kinds {
		if u := strings.TrimSpace(k.Url); u != "" {
			return u
		}
	}
	return ""
}

// exploreKindsJS 判断 exploreUrl 是否为 JS 形式，并截出脚本正文。
func exploreKindsJS(raw string) (string, bool) {
	lower := strings.ToLower(raw)
	switch {
	case strings.HasPrefix(lower, "@js:"):
		return raw[len("@js:"):], true
	case strings.HasPrefix(lower, "<js>"):
		// 容错：结尾的 </js> 缺失时按「到字符串结尾」处理，
		// 原版这里会抛下标越界，没必要跟着一起崩。
		body := raw[len("<js>"):]
		if i := strings.LastIndex(strings.ToLower(body), "</js>"); i >= 0 {
			body = body[:i]
		}
		return body, true
	}
	return "", false
}

// exploreKindsText 把 JS 执行结果转成待解析的文本。
// 书源通常返回 JSON 字符串，也有的直接 return 数组，两种都要接。
func exploreKindsText(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case []byte:
		return string(t)
	}
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprint(v)
	}
	return string(b)
}

// ExploreBook 发现书籍
func ExploreBook(src *model.BookSource, url string, page int) ([]*model.SearchBook, error) {
	// 未指定地址时用 exploreUrl 的第一个**非分组**分类
	if strings.TrimSpace(url) == "" {
		if kinds := GetExploreKinds(src); len(kinds) > 0 {
			if u := firstExploreUrl(kinds); u != "" {
				url = u
			}
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
	f, err := fetch(src, url, src.BookSourceUrl, nil, nil, &p, "")
	if err != nil {
		return nil, err
	}
	return analyzeBookList(src, rd, f.au, f.url, f.body, false, f.isRedirect)
}

// GetBookInfo 获取书籍详情
func GetBookInfo(src *model.BookSource, book *model.Book) error {
	// 对齐 legado：入口重置书籍类型，否则文件型书源走不到 downloadUrls 分支
	book.SetSourceType(src.GetBookType())
	if book.InfoHtml != "" {
		return analyzeBookInfo(src, book, book.BookUrl, book.BookUrl, book.InfoHtml)
	}
	f, err := fetch(src, book.BookUrl, src.BookSourceUrl, book, nil, nil, "")
	if err != nil {
		return err
	}
	return analyzeBookInfo(src, book, book.BookUrl, f.url, f.body)
}

// GetChapterList 获取目录
func GetChapterList(src *model.BookSource, book *model.Book, runPreUpdateJs bool) ([]*model.BookChapter, error) {
	book.SetSourceType(src.GetBookType())
	if runPreUpdateJs {
		if err := RunPreUpdateJs(src, book); err != nil {
			return nil, err
		}
	}
	if book.BookUrl == book.TocUrl && book.TocHtml != "" {
		return analyzeChapterList(src, book, book.TocUrl, book.TocUrl, book.TocHtml)
	}
	f, err := fetch(src, book.TocUrl, book.BookUrl, book, nil, nil, "")
	if err != nil {
		return nil, err
	}
	return analyzeChapterList(src, book, book.TocUrl, f.url, f.body)
}

// RunPreUpdateJs 执行目录预更新 JS。
// 对齐 Kotlin 的 `runPreUpdateJs(...).getOrThrow()`：脚本失败时中断目录抓取，
// 否则「目录地址要由脚本刷新」的书源会拿旧地址解析出空目录，只剩一句
// 「章节列表为空」的错误，看不到真实原因。
func RunPreUpdateJs(src *model.BookSource, book *model.Book) error {
	preUpdateJs := src.GetTocRule().PreUpdateJs
	if strings.TrimSpace(preUpdateJs) == "" {
		return nil
	}
	ar := rule.New(src).SetBook(book)
	ar.SetContent("")
	ar.InPreUpdateJs = true
	if _, err := ar.EvalJSErr(preUpdateJs); err != nil {
		return fmt.Errorf("preUpdateJs 执行失败: %w", err)
	}
	return nil
}

// GetContent 获取章节正文。
//
// 这里**不**重置 book.Type：正文是并发抓的（download 一个 book 多章同时跑），
// 写共享字段会被 race 检测出来。类型由 GetBookInfo / GetChapterList 这两个
// 串行入口设置，正文解析本身也不依赖它。
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
	// webJs / sourceRegex 依赖 WebView；这里照常传下去，将来接上不用再改调用点
	resp, err := au.GetStrResponseOpt(urlx.StrResponseOptions{
		JsStr:       contentRule.WebJs,
		SourceRegex: contentRule.SourceRegex,
	})
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
	logFetched(debug.StateSearchBody, au.RuleUrl, body)
	ar := newRule(src, nil, rd)
	ar.SetContent(body, baseUrl)
	ar.SetRedirectUrl(baseUrl)

	// 详情页直连判定
	if isSearch && src.BookUrlPattern != "" {
		if matched, err := regexp.MatchString(src.BookUrlPattern, baseUrl); err == nil && matched {
			debug.Log("≡链接为详情页")
			if sb := getInfoItem(src, ar, au, body, baseUrl, rd.ToJSON(), isRedirect); sb != nil {
				sb.InfoHtml = body
				bookList = append(bookList, sb)
			}
			logCount("书籍总数", len(bookList))
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

	debug.Log("┌获取书籍列表")
	collections := ar.GetElements(ruleList)
	if len(collections) == 0 && src.BookUrlPattern == "" {
		debug.Log("└列表为空,按详情页解析")
		if sb := getInfoItem(src, ar, au, body, baseUrl, rd.ToJSON(), isRedirect); sb != nil {
			sb.InfoHtml = body
			bookList = append(bookList, sb)
		}
		logCount("书籍总数", len(bookList))
		return bookList, nil
	}
	debug.Log("└列表大小:" + strconv.Itoa(len(collections)))

	ruleName := ar.SplitSourceRule(lr.GetName())
	ruleBookUrl := ar.SplitSourceRule(lr.GetBookUrl())
	ruleAuthor := ar.SplitSourceRule(lr.GetAuthor())
	ruleCover := ar.SplitSourceRule(lr.GetCoverUrl())
	ruleIntro := ar.SplitSourceRule(lr.GetIntro())
	ruleKind := ar.SplitSourceRule(lr.GetKind())
	ruleLast := ar.SplitSourceRule(lr.GetLastChapter())
	ruleWords := ar.SplitSourceRule(lr.GetWordCount())

	for i, item := range collections {
		// 只对首条打字段级日志，避免列表几十条时刷屏（对齐 Kotlin 的 log 参数）
		sb := getSearchItem(src, ar, item, baseUrl, rd.ToJSON(),
			ruleName, ruleBookUrl, ruleAuthor, ruleCover, ruleIntro, ruleKind, ruleLast, ruleWords, i == 0)
		if sb == nil {
			continue
		}
		if baseUrl == sb.BookUrl {
			sb.InfoHtml = body
		}
		bookList = append(bookList, sb)
	}
	// 去重：对齐 SearchBook.equals —— 只按 bookUrl 判重
	seen := map[string]bool{}
	unique := make([]*model.SearchBook, 0, len(bookList))
	for _, b := range bookList {
		if seen[b.BookUrl] {
			continue
		}
		seen[b.BookUrl] = true
		unique = append(unique, b)
	}
	if reverse {
		for i, j := 0, len(unique)-1; i < j; i, j = i+1, j-1 {
			unique[i], unique[j] = unique[j], unique[i]
		}
	}
	logCount("书籍总数", len(unique))
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
	book.SetSourceType(src.GetBookType())
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
	syncVariable(sb)
	return sb
}

// syncVariable 把变量表回写到 Variable 字段。
//
// 引擎里变量实际存在 VariableHolder（map）中，而 Book/SearchBook 对外的 Variable
// 是一个 JSON 字符串字段（对齐 Kotlin 里 variable 是 variableMap 的计算属性）。
// 跨进程/跨模块传递时要靠这个字段，所以在产出搜索结果前同步一次。
func syncVariable(sb *model.SearchBook) {
	if sb == nil {
		return
	}
	if s := sb.ToJSON(); s != "" {
		sb.Variable = s
	}
}

func getSearchItem(src *model.BookSource, ar *rule.AnalyzeRule, item any, baseUrl, variable string,
	ruleName, ruleBookUrl, ruleAuthor, ruleCover, ruleIntro, ruleKind, ruleLast, ruleWords []*rule.SourceRule,
	trace bool) *model.SearchBook {
	sb := model.NewSearchBook()
	if variable != "" {
		sb.LoadJSON(variable)
	}
	sb.Type = model.SourceTypeToBookType(src.GetBookType())
	sb.Origin = src.BookSourceUrl
	sb.OriginName = src.BookSourceName
	sb.OriginOrder = src.CustomOrder
	// 对齐 Kotlin 的 analyzeRule.setRuleData(searchBook)：@put 必须落到当前这条
	// 搜索结果自己的变量表，否则同一页多条结果会互相覆盖，变量也带不到目录/正文。
	ar.SetRuleData(sb)
	ar.SetContent(item)
	// tb 按 Kotlin 的 Debug.log(..., log) 语义，只对首条打字段级日志
	tb := func(label, val string) {
		if trace {
			debug.Pair(label, val)
		}
	}
	sb.Name = FormatBookName(ar.GetString(ruleName))
	tb("获取书名", sb.Name)
	if sb.Name == "" {
		return nil
	}
	sb.Author = FormatBookAuthor(ar.GetString(ruleAuthor))
	tb("获取作者", sb.Author)
	if kl := ar.GetStringList(ruleKind); len(kl) > 0 {
		sb.Kind = strings.Join(kl, ",")
	}
	tb("获取分类", sb.Kind)
	sb.WordCount = WordCountFormat(ar.GetString(ruleWords))
	tb("获取字数", sb.WordCount)
	sb.LatestChapterTitle = ar.GetString(ruleLast)
	tb("获取最新章节", sb.LatestChapterTitle)
	sb.Intro = util.HtmlFormat(ar.GetString(ruleIntro))
	tb("获取简介", sb.Intro)
	if cu := ar.GetString(ruleCover); cu != "" {
		sb.CoverUrl = util.GetAbsoluteURL(baseUrl, cu)
	}
	tb("获取封面链接", sb.CoverUrl)
	sb.BookUrl = ar.GetString(ruleBookUrl, true)
	if sb.BookUrl == "" {
		sb.BookUrl = baseUrl
	}
	tb("获取详情页链接", sb.BookUrl)
	syncVariable(sb)
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
	logFetched(debug.StateInfoBody, baseUrl, body)
	infoRule := src.GetBookInfoRule()
	if infoRule.Init != "" {
		debug.Log("≡执行详情页初始化规则")
		if el := ar.GetElement(infoRule.Init); el != nil {
			ar.SetContent(el)
		}
	}
	mCanReName := canReName && infoRule.CanReName != ""
	// 注意：└ 打印的是「规则求值结果」，不是合并后的 book 字段（对齐 Kotlin）。
	// 规则取空而保留旧值时，这里显示空——这正是书源作者需要看到的信号。
	n := FormatBookName(ar.GetString(infoRule.Name))
	if n != "" && (mCanReName || book.Name == "") {
		book.Name = n
	}
	debug.Pair("获取书名", n)
	a := FormatBookAuthor(ar.GetString(infoRule.Author))
	if a != "" && (mCanReName || book.Author == "") {
		book.Author = a
	}
	debug.Pair("获取作者", a)
	k := strings.Join(ar.GetStringList(infoRule.Kind), ",")
	if k != "" {
		book.Kind = k
	}
	debug.Pair("获取分类", k)
	w := WordCountFormat(ar.GetString(infoRule.WordCount))
	if w != "" {
		book.WordCount = w
	}
	debug.Pair("获取字数", w)
	l := ar.GetString(infoRule.LastChapter)
	if l != "" {
		book.LatestChapterTitle = l
	}
	debug.Pair("获取最新章节", l)
	i := util.HtmlFormat(ar.GetString(infoRule.Intro))
	if i != "" {
		book.Intro = i
	}
	debug.Pair("获取简介", i)
	c := ar.GetString(infoRule.CoverUrl)
	if c != "" {
		book.CoverUrl = util.GetAbsoluteURL(redirectUrl, c)
	}
	debug.Pair("获取封面链接", c)
	if !book.IsWebFile() {
		book.TocUrl = ar.GetString(infoRule.TocUrl, true)
		if book.TocUrl == "" {
			book.TocUrl = baseUrl
		}
		if book.TocUrl == baseUrl {
			book.TocHtml = body
		}
		debug.Pair("获取目录链接", book.TocUrl)
	} else {
		urls := ar.GetStringList(infoRule.DownloadUrls, true)
		if len(urls) == 0 {
			debug.Log("└")
			return fmt.Errorf("下载链接为空")
		}
		book.DownloadUrls = urls
		debug.Pair("获取文件下载链接", strings.Join(urls, "，\n"))
	}
	return nil
}

// —— 目录 ——

func analyzeChapterList(src *model.BookSource, book *model.Book, baseUrl, redirectUrl, body string) ([]*model.BookChapter, error) {
	if body == "" {
		return nil, fmt.Errorf("获取目录内容失败: %s", baseUrl)
	}
	logFetched(debug.StateTocBody, baseUrl, body)
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
	// 翻页：对齐 Kotlin 的三分支——0 个下一页不打日志、1 个顺序翻、多个并发解析
	visited := map[string]bool{redirectUrl: true}
	switch len(nextUrls) {
	case 0:
		// Kotlin 在 0 个下一页时不输出任何统计行
	case 1:
		next := nextUrls[0]
		for next != "" && !visited[next] {
			visited[next] = true
			au := urlx.New(urlx.Options{Url: next, Source: src, Book: book})
			resp, err := au.GetStrResponse()
			if err != nil || resp.Body == "" {
				break
			}
			more, nu := parseChapterPage(src, book, next, next, resp.Body, tocRule, listRule, false)
			chapters = append(chapters, more...)
			if len(nu) != 1 {
				break
			}
			next = nu[0]
		}
		logCount("目录总页数", len(visited))
	default:
		logCount("并发解析目录,总页数", len(nextUrls))
		pages := make([][]*model.BookChapter, len(nextUrls))
		var wg sync.WaitGroup
		for i, u := range nextUrls {
			wg.Go(func() {
				au := urlx.New(urlx.Options{Url: u, Source: src, Book: book})
				resp, err := au.GetStrResponse()
				if err != nil || resp.Body == "" {
					return
				}
				more, _ := parseChapterPage(src, book, u, resp.URL, resp.Body, tocRule, listRule, false)
				pages[i] = more
			})
		}
		wg.Wait()
		// 按地址顺序拼接，顺序稳定（Kotlin 用 mapAsync 按完成顺序 append，顺序不确定）
		for _, p := range pages {
			chapters = append(chapters, p...)
		}
	}
	if len(chapters) == 0 {
		debug.Log("◇章节列表为空")
		// 带上规则串与页面地址：只有「章节列表为空」时无从判断是站点改版、
		// 选择器写错还是页面根本是登录墙，排查全靠猜。
		return nil, fmt.Errorf("章节列表为空：目录规则 %q 在 %s 上未匹配到任何章节", listRule, baseUrl)
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
	// formatJs：同一 bindings 上逐章执行，gInt 由脚本自己累加（对齐 Kotlin）
	if tocRule.FormatJs != "" {
		gInt := 0
		for i, c := range unique {
			v, err := js.DefaultEngine().Eval(tocRule.FormatJs, &js.Bindings{
				Source:  src,
				Book:    book,
				Chapter: c,
				Title:   c.Title,
				Extra:   map[string]any{"index": i + 1},
				GInt:    &gInt,
			})
			if err == nil && v != nil {
				if s := fmt.Sprint(v); s != "" {
					c.Title = s
				}
			}
		}
	}
	book.TotalChapterNum = len(unique)
	logCount("目录总数", len(unique))
	if len(unique) > 0 {
		book.LatestChapterTitle = unique[len(unique)-1].Title
		book.DurChapterTitle = unique[min(book.DurChapterIndex, len(unique)-1)].Title
		debug.Lines(
			"≡首章信息",
			"◇章节名称:"+unique[0].Title,
			"◇章节链接:"+unique[0].Url,
			"◇章节信息:"+unique[0].Tag,
			"◇是否VIP:"+strconv.FormatBool(unique[0].IsVip),
			"◇是否购买:"+strconv.FormatBool(unique[0].IsPay),
		)
	}
	return unique, nil
}

func parseChapterPage(src *model.BookSource, book *model.Book, baseUrl, redirectUrl, body string, tocRule *model.TocRule, listRule string, getNext bool) ([]*model.BookChapter, []string) {
	ar := newRule(src, book, nil)
	ar.SetContent(body, baseUrl)
	ar.SetRedirectUrl(redirectUrl)
	// 只有首页（getNext=true）打目录解析日志，翻页时静默（对齐 Kotlin 的 log 参数）
	if getNext {
		debug.Log("┌获取目录列表")
	}
	elements := ar.GetElements(listRule)
	if getNext {
		debug.Log("└列表大小:" + strconv.Itoa(len(elements)))
	}
	nextUrls := []string{}
	if getNext && tocRule.NextTocUrl != "" {
		debug.Log("┌获取目录下一页列表")
		if l := ar.GetStringList(tocRule.NextTocUrl, true); l != nil {
			for _, u := range l {
				if u != redirectUrl {
					nextUrls = append(nextUrls, u)
				}
			}
		}
		debug.Log("└" + strings.Join(nextUrls, "，"))
	}
	chapters := make([]*model.BookChapter, 0, len(elements))
	if len(elements) == 0 {
		return chapters, nextUrls
	}
	if getNext {
		debug.Log("┌解析目录列表")
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
	if getNext {
		debug.Log("└目录列表解析完成")
	}
	return chapters, nextUrls
}

// —— 正文 ——

const (
	// maxContentPages 单章分页抓取的页数上限。规则异常时（例如每页都返回带
	// 自增参数的新地址）若不设上限会一直请求下去。
	maxContentPages = 50
	// maxContentConcurrency 规则一次命中多个分页链接时的并发度。
	maxContentConcurrency = 4
)

func analyzeContent(src *model.BookSource, book *model.Book, chapter *model.BookChapter, baseUrl, redirectUrl, body, nextChapterUrl string) (string, error) {
	if body == "" {
		return "", fmt.Errorf("获取正文内容失败: %s", baseUrl)
	}
	logFetched(debug.StateContentBody, baseUrl, body)
	contentRule := src.GetContentRule()
	// ruleContent.title：有些站目录页只有「第12章」，真标题只在正文页，
	// 取到值就回写章节名（legado 还会落库；桌面端没有 DB，回写对象即可，
	// download 拼文本用的就是它）。必须在解析正文之前执行，正文规则里的
	// {{title}} / chapter.title 才能拿到新标题。
	if titleRule := contentRule.Title; strings.TrimSpace(titleRule) != "" {
		ar := newRule(src, book, nil)
		ar.SetContent(body, baseUrl)
		ar.SetRedirectUrl(redirectUrl)
		ar.SetChapter(chapter)
		ar.SetNextChapterUrl(nextChapterUrl)
		if t := strings.TrimSpace(ar.GetString(titleRule)); t != "" {
			chapter.Title = t
		}
	}
	parts := []string{}
	// 已抓过的页（统一存绝对地址）。相对/绝对混用时也能正确去重，
	// 避免同一页被规则既给相对路径又给绝对路径时重复抓取。
	nextUrlList := []string{util.GetAbsoluteURL(redirectUrl, redirectUrl)}
	content, nextUrls := parseContent(src, book, chapter, baseUrl, redirectUrl, body, nextChapterUrl, true)
	parts = append(parts, content)

	switch {
	case len(nextUrls) == 1:
		// 逐页向后找：每页只给出一个「下一页」，直到没有下一页或撞上下一章。
		next := nextUrls[0]
		for next != "" && len(parts) < maxContentPages {
			absNext := util.GetAbsoluteURL(redirectUrl, next)
			if contains(nextUrlList, absNext) {
				break
			}
			// 有些源的「下一页」规则会选中「下一章」链接，撞上就停，
			// 否则会把下一章正文拼到本章结尾。
			if nextChapterUrl != "" &&
				absNext == util.GetAbsoluteURL(redirectUrl, nextChapterUrl) {
				break
			}
			nextUrlList = append(nextUrlList, absNext)
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

	case len(nextUrls) > 1:
		// 规则一次命中多页（例如 CSS 选择器选中了页面上所有分页链接）。
		// 原版 legado 在这种情况并发抓取全部链接，并且不再往下递归找「下一页」，
		// 否则会把同一批链接反复抓。这里对齐：并发抓、按原顺序拼、不递归。
		pages := make([]string, len(nextUrls))
		var wg sync.WaitGroup
		sem := make(chan struct{}, maxContentConcurrency)
		for i, u := range nextUrls {
			absU := util.GetAbsoluteURL(redirectUrl, u)
			if contains(nextUrlList, absU) {
				continue
			}
			if nextChapterUrl != "" && absU == util.GetAbsoluteURL(redirectUrl, nextChapterUrl) {
				continue
			}
			nextUrlList = append(nextUrlList, absU)
			wg.Add(1)
			go func(i int, u string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()
				au := urlx.New(urlx.Options{Url: u, Source: src, Book: book, Chapter: chapter})
				resp, err := au.GetStrResponse()
				if err != nil || resp.Body == "" {
					return
				}
				c, _ := parseContent(src, book, chapter, u, resp.URL, resp.Body, nextChapterUrl, false)
				pages[i] = c
			}(i, u)
		}
		wg.Wait()
		for _, c := range pages {
			if strings.TrimSpace(c) != "" {
				parts = append(parts, c)
			}
		}
	}
	contentStr := strings.Join(parts, "\n")
	// 全文替换（对齐 Kotlin 的三步：按行 trim → 替换 → 统一补行首缩进）。
	// 早期实现只在替换结果为空时补缩进，替换成功时既不 trim 也不缩进，
	// 带 `^\s*`、`\n\s+` 类正则的书源匹配位置会和 App 里不一致。
	if contentRule.ReplaceRegex != "" {
		trimmed := trimEachLine(contentStr)
		ar := newRule(src, book, nil)
		ar.SetContent(trimmed)
		ar.SetChapter(chapter)
		if replaced := ar.GetString(contentRule.ReplaceRegex); strings.TrimSpace(replaced) != "" {
			contentStr = indentEachLine(replaced)
		} else {
			contentStr = indentEachLine(trimmed)
		}
	}
	if !chapter.IsVolume && strings.TrimSpace(contentStr) == "" {
		return "", fmt.Errorf("内容为空")
	}
	logCount("本章总页数", len(nextUrlList))
	debug.Pair("获取章节名称", chapter.Title)
	debug.Pair("获取正文内容", "\n"+contentStr)
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
			debug.Log("┌获取正文下一页链接")
			if l := ar.GetStringList(nr, true); l != nil {
				nextUrls = append(nextUrls, l...)
			}
			debug.Log("└" + strings.Join(nextUrls, "，"))
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
	return slices.Contains(a, s)
}

// trimEachLine 逐行 trim（对齐 Kotlin `split(LF).joinToString("\n") { it.trim() }`）
func trimEachLine(s string) string {
	lines := strings.Split(s, "\n")
	for i := range lines {
		lines[i] = strings.TrimSpace(lines[i])
	}
	return strings.Join(lines, "\n")
}

// indentEachLine 逐行补两个全角空格缩进
func indentEachLine(s string) string {
	lines := strings.Split(s, "\n")
	for i := range lines {
		lines[i] = "\u3000\u3000" + lines[i]
	}
	return strings.Join(lines, "\n")
}

func isTrue(s string) bool {
	t := strings.ToLower(strings.TrimSpace(s))
	return t == "true" || t == "1" || t == "yes"
}
