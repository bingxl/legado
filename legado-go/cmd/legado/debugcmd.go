package main

import (
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"

	"github.com/legado/legado-go/pkg/debug"
	"github.com/legado/legado-go/pkg/js"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/util"
	"github.com/legado/legado-go/pkg/webbook"
)

// —— 书源调试 ——
//
// 对齐客户端「书源调试」界面（Kotlin 的 Debug.startDebug）：
// 按 -key 的形态决定从哪一步进入，然后顺着 搜索/发现 → 详情 → 目录 → 正文 往下跑，
// 每一步的请求、规则求值、响应都按 [mm:ss.SSS] 打在同一个流里。
//
// 与客户端一致的符号：≡ 提示、︾/︽ 阶段起止、┌/└ 规则组、◇ 统计。
// 与客户端的差异：客户端把响应体留给「查看源码」按钮，这里由 -body / -save-dir 决定去处。

// dbgStage 调试链路的最大执行深度
type dbgStage int

const (
	dbgStageSearch dbgStage = iota
	dbgStageExplore
	dbgStageInfo
	dbgStageToc
	dbgStageContent
)

func parseDbgStage(s string) (dbgStage, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "all":
		return dbgStageContent, nil
	case "search":
		return dbgStageSearch, nil
	case "explore":
		return dbgStageExplore, nil
	case "info", "detail":
		return dbgStageInfo, nil
	case "toc", "catalog":
		return dbgStageToc, nil
	case "content", "chapter":
		return dbgStageContent, nil
	}
	return dbgStageContent, fmt.Errorf("未知的 -stage 取值 %q（可选 all / search / explore / info / toc / content）", s)
}

// dbgRun 一次调试过程的状态
type dbgRun struct {
	src    *model.BookSource
	max    dbgStage
	failed bool
}

func (d *dbgRun) allow(s dbgStage) bool { return d.max >= s }

// fail 记一条错误并把整次调试标记为失败（对应 Kotlin 的 state = -1）
func (d *dbgRun) fail(stage string, err error) {
	d.failed = true
	debug.Errorf("⇒%s失败: %v", stage, err)
}

func (d *dbgRun) newBook() *model.Book {
	book := model.NewBook()
	book.Origin = d.src.BookSourceUrl
	book.OriginName = d.src.BookSourceName
	book.Type = d.src.GetBookType()
	return book
}

func cmdDebug(args []string) {
	fs, g := newFlags("debug")
	fs.Usage = func() { fmt.Fprintln(os.Stderr, debugUsage()) }
	key := fs.String("key", "", "调试入口：关键字=搜索 | 绝对URL=详情页 | 分类::地址=发现页 | ++地址=目录页 | --地址=正文页")
	stage := fs.String("stage", "all", "最深执行到哪一步: all|search|explore|info|toc|content")
	body := fs.String("body", "none", "响应体输出: none|head|full（配置项无对应项）")
	bodyLimit := fs.Int("body-limit", 2048, "-body head 时的字节上限")
	saveDir := fs.String("save-dir", "", "把各阶段响应体另存到该目录（对齐客户端「查看源码」）")
	asJSON := fs.Bool("json", false, "日志按 JSONL 输出，便于管道处理")
	outFile := fs.String("o", "", "日志写入文件（默认 stdout）")
	colorMode := fs.String("color", "auto", "着色: auto|always|never")
	maxChars := fs.Int("max-chars", 0, "单条日志最大字数，0 表示不限制（正文很长时用它压一压）")
	g.parse(args)

	if *key == "" && fs.NArg() > 0 {
		*key = fs.Arg(0)
	}
	entry := strings.TrimSpace(*key)
	if entry == "" {
		failf("%s", debugUsage())
	}
	maxStage, err := parseDbgStage(*stage)
	if err != nil {
		failf("错误: %v", err)
	}
	bodyMode, err := debug.ParseBodyMode(*body)
	if err != nil {
		failf("错误: %v", err)
	}

	e := newEngine(g)
	src := resolveSource(e, g)

	// 书源里的 java.log / console.log 直接进调试流（客户端也是这样）
	js.OnLog = func(msg string) { debug.Log(msg) }

	out, closeOut, err := openDebugOutput(*outFile)
	if err != nil {
		failErr("打开日志文件", err)
	}
	defer closeOut()

	var sinks []debug.Sink
	if *asJSON {
		sinks = append(sinks, &debug.JSONSink{
			W:         out,
			BodyMode:  bodyMode,
			BodyLimit: *bodyLimit,
			MsgLimit:  *maxChars,
		})
	} else {
		sinks = append(sinks, &debug.TextSink{
			W:         out,
			Color:     colorEnabled(*colorMode, out),
			BodyMode:  bodyMode,
			BodyLimit: *bodyLimit,
			MsgLimit:  *maxChars,
		})
	}
	if *saveDir != "" {
		sinks = append(sinks, &debug.FileBodySink{Dir: *saveDir})
	}
	debug.SetSink(debug.Multi(sinks...))
	defer debug.SetSink(nil)

	d := &dbgRun{src: src, max: maxStage}
	d.run(entry)
	debug.Done("︽解析完成")
	if d.failed {
		os.Exit(1)
	}
}

// run 按 -key 的形态分派入口，对齐 Kotlin Debug.startDebug
func (d *dbgRun) run(key string) {
	switch {
	case util.IsAbsUrl(key):
		book := d.newBook()
		book.BookUrl = key
		debug.Log("⇒开始访问详情页:" + key)
		d.infoDebug(book)

	case strings.Contains(key, "::"):
		prefix, rest, _ := strings.Cut(key, "::")
		url, err := d.exploreURL(prefix, rest)
		if err != nil {
			d.fail("发现页", err)
			return
		}
		debug.Log("⇒开始访问发现页:" + url)
		d.exploreDebug(url)

	case strings.HasPrefix(key, "++"):
		url := strings.TrimSpace(key[len("++"):])
		book := d.newBook()
		book.TocUrl = url
		debug.Log("⇒开始访问目录页:" + url)
		d.tocDebug(book)

	case strings.HasPrefix(key, "--"):
		url := strings.TrimSpace(key[len("--"):])
		book := d.newBook()
		chapter := model.NewBookChapter(book.BookUrl)
		chapter.Title = "调试"
		chapter.Url = url
		debug.Log("⇒开始访问正文页:" + url)
		d.contentDebug(book, chapter, "")

	default:
		debug.Log("⇒开始搜索关键字:" + key)
		d.searchDebug(key)
	}
}

// exploreURL 解析 "分类::地址"：地址为空时按分类名查 exploreUrl，分类名为空时取第一个
func (d *dbgRun) exploreURL(prefix, rest string) (string, error) {
	if u := strings.TrimSpace(rest); u != "" {
		return u, nil
	}
	kinds := webbook.GetExploreKinds(d.src)
	if len(kinds) == 0 {
		return "", fmt.Errorf("书源没有 exploreUrl，无法调试发现页；可直接用 -key 传完整地址")
	}
	name := strings.TrimSpace(prefix)
	if name == "" {
		return kinds[0].Url, nil
	}
	names := make([]string, 0, len(kinds))
	for _, k := range kinds {
		if k.Title == name {
			return k.Url, nil
		}
		names = append(names, k.Title)
	}
	return "", fmt.Errorf("分类 %q 不存在，可选: %s", name, strings.Join(names, " / "))
}

func (d *dbgRun) searchDebug(keyword string) {
	debug.Log("︾开始解析搜索页")
	list, err := webbook.SearchBook(d.src, keyword, 1)
	if err != nil {
		d.fail("搜索页", err)
		return
	}
	if len(list) == 0 {
		d.failed = true
		debug.Errorf("︽未获取到书籍")
		return
	}
	debug.Log("︽搜索页解析完成")
	if !d.allow(dbgStageInfo) {
		return
	}
	d.infoDebug(list[0].ToBook())
}

func (d *dbgRun) exploreDebug(url string) {
	debug.Log("︾开始解析发现页")
	list, err := webbook.ExploreBook(d.src, url, 1)
	if err != nil {
		d.fail("发现页", err)
		return
	}
	if len(list) == 0 {
		d.failed = true
		debug.Errorf("︽未获取到书籍")
		return
	}
	debug.Log("︽发现页解析完成")
	if !d.allow(dbgStageInfo) {
		return
	}
	d.infoDebug(list[0].ToBook())
}

func (d *dbgRun) infoDebug(book *model.Book) {
	if !d.allow(dbgStageInfo) {
		return
	}
	if book.TocUrl != "" {
		debug.Log("≡已获取目录链接,跳过详情页")
		d.tocDebug(book)
		return
	}
	debug.Log("︾开始解析详情页")
	if err := webbook.GetBookInfo(d.src, book); err != nil {
		d.fail("详情页", err)
		return
	}
	debug.Log("︽详情页解析完成")
	if book.IsWebFile() {
		debug.Log("≡文件类书源跳过解析目录")
		return
	}
	d.tocDebug(book)
}

func (d *dbgRun) tocDebug(book *model.Book) {
	if !d.allow(dbgStageToc) {
		return
	}
	debug.Log("︾开始解析目录页")
	chapters, err := webbook.GetChapterList(d.src, book, true)
	if err != nil {
		d.fail("目录页", err)
		return
	}
	debug.Log("︽目录页解析完成")
	// 卷名不算正文（对齐 Kotlin tocDebug 的过滤）
	toc := make([]*model.BookChapter, 0, len(chapters))
	for _, c := range chapters {
		if c.IsVolume && strings.HasPrefix(c.Url, c.Title) {
			continue
		}
		toc = append(toc, c)
	}
	if len(toc) == 0 {
		d.failed = true
		debug.Errorf("≡没有正文章节")
		return
	}
	next := toc[0].Url
	if len(toc) > 1 {
		next = toc[1].Url
	}
	d.contentDebug(book, toc[0], next)
}

func (d *dbgRun) contentDebug(book *model.Book, chapter *model.BookChapter, nextChapterURL string) {
	if !d.allow(dbgStageContent) {
		return
	}
	debug.Log("︾开始解析正文页")
	if _, err := webbook.GetContent(d.src, book, chapter, nextChapterURL); err != nil {
		d.fail("正文页", err)
		return
	}
	debug.Log("︽正文页解析完成")
}

// —— 小工具 ——

func openDebugOutput(path string) (io.Writer, func(), error) {
	if strings.TrimSpace(path) == "" {
		return os.Stdout, func() {}, nil
	}
	f, err := os.Create(path)
	if err != nil {
		return nil, nil, err
	}
	return f, func() { _ = f.Close() }, nil
}

// colorEnabled auto 模式下只在类 Unix 终端着色：
// Windows 的 conhost 默认不解析 ANSI 转义，要颜色请显式 -color=always。
func colorEnabled(mode string, w io.Writer) bool {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "always", "force", "on", "yes":
		return true
	case "never", "off", "no":
		return false
	}
	if runtime.GOOS == "windows" {
		return false
	}
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	st, err := f.Stat()
	if err != nil {
		return false
	}
	return st.Mode()&os.ModeCharDevice != 0
}

func debugUsage() string {
	const pad = "  "
	return strings.Join([]string{
		"用法: legado debug -key <入口> [其他选项]",
		"",
		"入口（按形态自动分派，对齐客户端书源调试）:",
		pad + "-key 海贼王                     搜索「海贼王」，再顺着详情→目录→正文往下跑",
		pad + "-key https://site.com/book/1    从详情页开始",
		pad + "-key 冒险::                    发现页：按分类名从 exploreUrl 查地址",
		pad + "-key ::https://site.com/sort/1  发现页：直接给地址",
		pad + "-key ++https://site.com/toc    从目录页开始",
		pad + "-key --https://site.com/c/1    从正文页开始",
		"",
		"选项:",
		pad + "-stage all|search|explore|info|toc|content   跑到哪一步停（默认 all）",
		pad + "-body none|head|full    响应体怎么输出（默认 none，只给摘要）",
		pad + "-body-limit 2048        -body head 的截断字节数",
		pad + "-save-dir dir           把 search/info/toc/content 响应体另存成文件",
		pad + "-max-chars 300          单条日志最多 300 字（默认 0 不限制，正文很长时用）",
		pad + "-json                   日志按 JSONL 输出",
		pad + "-o log.txt              日志写入文件",
		pad + "-color auto|always|never",
		"",
		"示例:",
		pad + "legado debug -dir ../sources -source 狼人小说 -key 监禁王",
		pad + "legado debug -dir ../sources -source 漫画客 -key :: -body head -save-dir ./dbg",
		"",
		"提示: 调试流里的 ≡ 是提示、︾/︽ 是阶段起止、┌/└ 是规则组、◇ 是统计。",
	}, "\n")
}
