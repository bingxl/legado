package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/legado/legado-go"
	"github.com/legado/legado-go/pkg/download"
	"github.com/legado/legado-go/pkg/js"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/source"
)

// —— 书目相关命令 ——
//
// search / explore / info / toc / content / download 共用同一套流程：
// 解析参数 → 建引擎 → 归一化 -source → 组装 book → 调引擎 → 打印。
// 共用的片段抽在下面的 helper 里，命令本身只保留各自的差异。

func cmdSearch(args []string) {
	fs, g := newFlags("search")
	key := fs.String("key", "", "搜索关键字（必填）")
	page := fs.Int("page", 1, "页码")
	limit := fs.Int("limit", 20, "最多显示条数")
	g.parse(args)
	argOr(fs, key)

	if strings.TrimSpace(*key) == "" {
		failf("请用 -key 指定搜索关键字，例如: legado search -dir ./sources -source 漫画客 -key 海贼")
	}
	e := newEngine(g)
	resolveSource(e, g)

	list, err := e.Search(g.source, *key, *page)
	if err != nil {
		failErr("搜索", err)
	}
	fmt.Printf("搜索「%s」命中 %d 条\n", *key, len(list))
	printBooks(list, *limit)
}

func cmdExplore(args []string) {
	fs, g := newFlags("explore")
	url := fs.String("url", "", "发现地址")
	page := fs.Int("page", 1, "页码")
	limit := fs.Int("limit", 20, "最多显示条数")
	g.parse(args)

	e := newEngine(g)
	resolveSource(e, g)

	list, err := e.Explore(g.source, *url, *page)
	if err != nil {
		failErr("发现", err)
	}
	fmt.Printf("发现命中 %d 条\n", len(list))
	printBooks(list, *limit)
}

func cmdInfo(args []string) {
	fs, g := newFlags("info")
	bookUrl := fs.String("book", "", "书籍详情页地址")
	name := fs.String("name", "", "书名（书源无 ruleBookInfo 时手动指定）")
	author := fs.String("author", "", "作者")
	g.parse(args)
	argOr(fs, bookUrl)

	e := newEngine(g)
	resolveSource(e, g)
	book := openBook(e, g, *bookUrl, *name, *author)

	fmt.Printf("书名: %s\n作者: %s\n分类: %s\n字数: %s\n最新: %s\n封面: %s\n目录: %s\n简介: %s\n",
		book.Name, book.Author, book.Kind, book.WordCount,
		book.LatestChapterTitle, book.CoverUrl, book.TocUrl, firstLine(book.Intro, 120))
}

func cmdToc(args []string) {
	fs, g := newFlags("toc")
	bookUrl := fs.String("book", "", "书籍详情页地址")
	limit := fs.Int("limit", 30, "最多显示条数")
	all := fs.Bool("all", false, "显示全部")
	name := fs.String("name", "", "书名（书源无 ruleBookInfo 时手动指定）")
	author := fs.String("author", "", "作者")
	g.parse(args)
	argOr(fs, bookUrl)

	e := newEngine(g)
	resolveSource(e, g)
	book := openBook(e, g, *bookUrl, *name, *author)
	chapters := chapterList(e, g, book)

	fmt.Printf("《%s》共 %d 章\n", book.Name, len(chapters))
	show := len(chapters)
	if !*all && show > *limit {
		show = *limit
	}
	for i := 0; i < show; i++ {
		fmt.Printf("%5d. %s\n", chapters[i].Index+1, chapters[i].Title)
	}
	if show < len(chapters) {
		fmt.Printf("... 其余 %d 章未显示（用 -all 查看）\n", len(chapters)-show)
	}
}

func cmdContent(args []string) {
	fs, g := newFlags("content")
	bookUrl := fs.String("book", "", "书籍详情页地址")
	index := fs.Int("index", 0, "章节下标（从 0 开始）")
	maxChars := fs.Int("len", 800, "预览字数")
	name := fs.String("name", "", "书名（书源无 ruleBookInfo 时手动指定）")
	author := fs.String("author", "", "作者")
	g.parse(args)
	argOr(fs, bookUrl)

	e := newEngine(g)
	resolveSource(e, g)
	book := openBook(e, g, *bookUrl, *name, *author)
	chapters := chapterList(e, g, book)

	if *index < 0 || *index >= len(chapters) {
		failf("章节下标越界，目录共 %d 章", len(chapters))
	}
	chapter := chapters[*index]
	// 下一章地址用于正文分页的刹车判定，不传会让「下一页」规则误把下一章拼进来
	next := ""
	if *index+1 < len(chapters) {
		next = chapters[*index+1].Url
	}
	content, err := e.GetContent(g.source, book, chapter, next)
	if err != nil {
		failErr("获取正文", err)
	}

	fmt.Printf("── %s（共 %d 字）\n", chapter.Title, len([]rune(content)))
	runes := []rune(content)
	if *maxChars > 0 && len(runes) > *maxChars {
		runes = runes[:*maxChars]
	}
	fmt.Println(string(runes))
	fmt.Println("…")
}

func cmdDownload(args []string) {
	fs, g := newFlags("download")
	b := baseCfg.Download
	bookUrl := fs.String("book", "", "书籍详情页地址，或使用 -key 搜索后下载第一本")
	key := fs.String("key", "", "搜索关键字（不给 -book 时使用）")
	out := fs.String("out", b.OutDir, "输出目录（配置项 download.outDir）")
	format := fs.String("format", b.Format, "输出格式: txt | md | images（配置项 download.format）")
	workers := fs.Int("workers", b.Workers, "并发数（配置项 download.workers）")
	maxCh := fs.Int("max", b.Max, "最多下载章节数，0 表示全部（配置项 download.max）")
	start := fs.Int("start", b.Start, "起始章节下标（配置项 download.start）")
	name := fs.String("name", "", "书名（书源无 ruleBookInfo 时手动指定）")
	author := fs.String("author", "", "作者")
	g.parse(args)
	argOr(fs, bookUrl)

	e := newEngine(g)
	resolveSource(e, g)
	js.OnLog = func(msg string) {
		if g.debug {
			fmt.Fprintln(os.Stderr, msg)
		}
	}

	book := downloadBook(e, g, *bookUrl, *key)
	applyBookMeta(book, *name, *author)

	last := 0
	res, err := e.Download(g.source, book, download.Options{
		OutDir:  *out,
		Format:  *format,
		Workers: *workers,
		Max:     *maxCh,
		Start:   *start,
		Progress: func(done, total int, title string) {
			pct := done * 100 / max(total, 1)
			// 每 10% 刷新一次，避免刷屏
			if pct/10 > last/10 || done == total {
				last = done
				fmt.Printf("\r进度 %d%% (%d/%d) %s        ", pct, done, total, title)
			}
		},
	})
	fmt.Println()
	if err != nil {
		failErr("下载", err)
	}
	fmt.Println(res.String())
	_ = e.SaveCookies()
}

// —— 共用 helper ——

// openBook 组装 book 对象并拉取详情（失败即退出）
func openBook(e *legado.Engine, g *globalFlags, bookUrl, name, author string) *model.Book {
	book := newBook(g, bookUrl)
	applyBookMeta(book, name, author)
	if err := e.GetBookInfo(g.source, book); err != nil {
		failErr("获取详情", err)
	}
	return book
}

// chapterList 拉取目录（失败即退出）
func chapterList(e *legado.Engine, g *globalFlags, book *model.Book) []*model.BookChapter {
	chapters, err := e.GetChapterList(g.source, book)
	if err != nil {
		failErr("获取目录", err)
	}
	return chapters
}

// downloadBook 按 -book 直连，或用 -key 搜索后取第一本
func downloadBook(e *legado.Engine, g *globalFlags, bookUrl, key string) *model.Book {
	if bookUrl != "" {
		return newBook(g, bookUrl)
	}
	if key == "" {
		failf("请指定 -book 或 -key")
	}
	list, err := e.Search(g.source, key, 1)
	if err != nil {
		failErr("搜索", err)
	}
	if len(list) == 0 {
		failf("搜索「%s」无结果", key)
	}
	book := list[0].ToBook()
	fmt.Printf("选中: 《%s》 %s\n", book.Name, book.Author)
	return book
}

// newBook 建一个归属当前书源的空白 book
func newBook(g *globalFlags, bookUrl string) *model.Book {
	book := model.NewBook()
	book.BookUrl = bookUrl
	book.Origin = g.source
	return book
}

// printBooks 输出搜索/发现结果，最多 limit 条
func printBooks(list []*model.SearchBook, limit int) {
	for i, b := range list {
		if i >= limit {
			break
		}
		fmt.Printf("%3d. %-28s %-14s %s\n", i+1, b.Name, b.Author, b.BookUrl)
	}
}

// resolveSource 把 -source 归一化成 bookSourceUrl，并给出留空/多重匹配提示。
// 匹配不到时打印候选清单并退出（返回 nil）。
func resolveSource(e *legado.Engine, g *globalFlags) *model.BookSource {
	matches := source.MatchAll(e.Sources, g.source)
	if len(matches) == 0 {
		fmt.Fprintf(os.Stderr, "未找到书源: %q\n%s\n", g.source, source.HintNotFound(e.Sources))
		os.Exit(1)
	}
	if g.source == "" && len(e.Sources) > 1 {
		fmt.Fprintf(os.Stderr, "提示: 未指定 -source，使用第 1 个书源「%s」（共 %d 个，用 list 查看）\n",
			matches[0].BookSourceName, len(e.Sources))
	}
	if len(matches) > 1 {
		names := make([]string, 0, len(matches))
		for _, s := range matches {
			names = append(names, s.BookSourceName)
		}
		fmt.Fprintf(os.Stderr, "提示: -source %q 匹配到 %d 个书源，已用「%s」；可用序号或完整名称精确指定。候选: %s\n",
			g.source, len(matches), matches[0].BookSourceName, strings.Join(names, " / "))
	}
	g.source = matches[0].BookSourceUrl
	return matches[0]
}

// applyBookMeta 补充书籍元信息：纯发现源常无 ruleBookInfo，
// 走 -book 直连时书名/作者只能由命令行给出
func applyBookMeta(book *model.Book, name, author string) {
	if name != "" {
		book.Name = name
	}
	if author != "" {
		book.Author = author
	}
}

func cmdList(args []string) {
	_, g := newFlags("list")
	g.parse(args)
	e := newEngine(g)

	fmt.Printf("共加载 %d 个书源\n", len(e.Sources))
	for i, s := range e.Sources {
		fmt.Printf("%3d. %s [%s] %s %s\n", i+1, pad(s.BookSourceName, 26), bookTypeText(s), pad(s.BookSourceUrl, 38), s.FileName)
	}
	fmt.Println("\n-source 可用：上面的序号、名称、bookSourceUrl、域名，或最后一列的文件名")
}

// bookTypeText 书源类型的中文名
func bookTypeText(s *model.BookSource) string {
	switch s.GetBookType() {
	case model.BookTypeAudio:
		return "音频"
	case model.BookTypeImage:
		return "图片/漫画"
	case model.BookTypeFile:
		return "文件"
	}
	return "文本"
}
