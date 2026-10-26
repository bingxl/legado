package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/legado/legado-go"
	"github.com/legado/legado-go/pkg/config"
	"github.com/legado/legado-go/pkg/download"
	"github.com/legado/legado-go/pkg/js"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/source"
)

var (
	// curEngine 当前引擎，供退出前统一落盘 Cookie
	curEngine *legado.Engine
	// baseCfg 是 config.json 解析出的默认值，作为各命令行参数的默认值
	baseCfg = config.Default()
	// cfgPath 是本次实际使用的配置文件路径（空表示不使用配置文件）
	cfgPath = config.FileName
)

func main() {
	// 正常结束时落盘 Cookie（os.Exit 的异常路径不会走到）
	defer func() {
		if curEngine != nil {
			_ = curEngine.SaveCookies()
		}
	}()
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	cmd := os.Args[1]
	args := os.Args[2:]

	if cmd == "help" || cmd == "-h" || cmd == "--help" {
		usage()
		return
	}

	if cmd == "help" || cmd == "-h" || cmd == "--help" {
		usage()
		return
	}
	// config 命令自己处理配置文件，不预加载
	switch cmd {
	case "config", "config-gen", "config-check":
		if cmd == "config-gen" {
			cmdConfigGen(args)
		} else if cmd == "config-check" {
			cmdConfigCheck(args, true)
		} else {
			cmdConfig(args)
		}
		return
	}

	// 第一步：读配置（-config 指定的，或当前目录的 config.json）
	// 第二步：各命令解析命令行，同名参数覆盖配置
	path, explicit := scanConfigPath(args)
	if err := initConfig(path, explicit); err != nil {
		fmt.Fprintln(os.Stderr, "读取配置失败:", configErrText(path, err))
		if !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintln(os.Stderr, "（用 -config= 可跳过配置；legado config check 可定位问题）")
		}
		os.Exit(1)
	}

	switch cmd {
	case "validate", "check":
		cmdValidate(args)
	case "list", "sources":
		cmdList(args)
	case "search":
		cmdSearch(args)
	case "explore":
		cmdExplore(args)
	case "info":
		cmdInfo(args)
	case "toc":
		cmdToc(args)
	case "content":
		cmdContent(args)
	case "download":
		cmdDownload(args)
	default:
		if strings.HasPrefix(cmd, "-") {
			fmt.Fprintf(os.Stderr, "全局选项要写在命令后面，例如: legado list -config my.json\n\n")
		} else {
			fmt.Fprintf(os.Stderr, "未知命令: %s\n\n", cmd)
		}
		usage()
		os.Exit(1)
	}
}

type globalFlags struct {
	dir     string
	file    string
	source  string
	cookie  string
	cache   string
	ua      string
	timeout int
	jsTime  int
	debug   bool

	configPath  string
	fs          *flag.FlagSet
	explicitDir bool // 命令行是否显式给了 -dir
}

// newFlags 建好命令的 FlagSet，并把 config.json 的值作为各参数默认值。
// 顺序保证「配置在前、命令行在后」：命令行只要出现就覆盖同名配置项。
func newFlags(name string) (*flag.FlagSet, *globalFlags) {
	fs := flag.NewFlagSet(name, flag.ExitOnError)
	g := &globalFlags{fs: fs, configPath: cfgPath}
	b := baseCfg

	fs.StringVar(&g.dir, "dir", b.SourceDir, "书源文件夹（配置项 sourceDir）")
	fs.StringVar(&g.file, "file", b.SourceFile, "单个书源文件（配置项 sourceFile，优先于 -dir）")
	fs.StringVar(&g.source, "source", b.Source, "书源: 序号(1/#1) | 名称 | bookSourceUrl | 域名 | 详情页 URL | 文件名；留空取第 1 个（配置项 source）")
	fs.StringVar(&g.cookie, "cookie", b.CookieFile, "Cookie 持久化文件（配置项 cookieFile；-cookie= 关闭持久化）")
	fs.StringVar(&g.cache, "cache", b.CacheFile, "缓存持久化文件（配置项 cacheFile；-cache= 关闭持久化）")
	fs.StringVar(&g.ua, "ua", b.UserAgent, "自定义 User-Agent（配置项 userAgent）")
	fs.IntVar(&g.timeout, "timeout", b.HTTPTimeout, "HTTP 超时(秒)（配置项 httpTimeout）")
	fs.IntVar(&g.jsTime, "js-timeout", b.JSTimeout, "JS 执行超时(秒)（配置项 jsTimeout）")
	fs.BoolVar(&g.debug, "debug", b.Debug, "输出调试日志（配置项 debug）")
	fs.StringVar(&g.configPath, "config", cfgPath, "配置文件路径，默认 config.json；-config= 表示不读配置")
	return fs, g
}

// parse 解析命令行，并把「命令行与配置冲突」的情形就地修正
func (g *globalFlags) parse(args []string) {
	_ = g.fs.Parse(args)
	set := map[string]bool{}
	g.fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	g.explicitDir = set["dir"]

	// -file 在库里优先级高于 -dir。命令行显式给了 -dir 而配置里有 sourceFile 时，
	// 若不清掉 file，用户会发现 -dir 没生效。
	if set["dir"] && !set["file"] {
		g.file = ""
	}
	if g.timeout <= 0 {
		g.timeout = 30
	}
	if g.jsTime <= 0 {
		g.jsTime = 30
	}
}

// scanConfigPath 在子命令参数里预扫描 -config。
// 必须早于 flag 解析：各命令参数的默认值要来自配置，而配置路径本身也是参数。
func scanConfigPath(args []string) (path string, explicit bool) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-config" || a == "--config":
			if i+1 < len(args) {
				return args[i+1], true
			}
			return "", true
		case strings.HasPrefix(a, "-config="):
			return a[len("-config="):], true
		case strings.HasPrefix(a, "--config="):
			return a[len("--config="):], true
		}
	}
	return config.FileName, false
}

// initConfig 读取配置文件，作为后续命令行参数的默认值。
// 默认路径 config.json 不存在时静默用内置默认；-config 显式指定却读不到则报错。
func initConfig(path string, explicit bool) error {
	if path == "" { // -config=：完全不读配置文件
		baseCfg = config.Default()
		cfgPath = ""
		return nil
	}
	c, err := config.Load(path)
	if err != nil {
		if !explicit && errors.Is(err, os.ErrNotExist) {
			baseCfg = config.Default()
			cfgPath = ""
			return nil
		}
		return err
	}
	c.Normalize()
	baseCfg = c
	cfgPath = path
	if len(c.UnknownFields()) > 0 {
		fmt.Fprintf(os.Stderr, "提示: %s 有未识别的配置项 %s，运行 legado config check 查看建议\n",
			path, strings.Join(c.UnknownFields(), ", "))
	}
	return nil
}

func newEngine(g *globalFlags) *legado.Engine {
	e, err := legado.New(legado.Config{
		SourceDir:   g.dir,
		SourceFile:  g.file,
		CookieFile:  g.cookie,
		CacheFile:   g.cache,
		UserAgent:   g.ua,
		HTTPTimeout: time.Duration(g.timeout) * time.Second,
		JSTimeout:   time.Duration(g.jsTime) * time.Second,
		Log: func(msg string) {
			if g.debug {
				fmt.Fprintln(os.Stderr, msg)
			}
		},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "错误:", err)
		if e != nil {
			for _, le := range e.LoadErrors {
				if le.Error() != err.Error() {
					fmt.Fprintln(os.Stderr, "加载警告:", le)
				}
			}
		}
		if !g.explicitDir && cfgPath != "" {
			fmt.Fprintf(os.Stderr, "当前书源目录来自配置文件 %s 的 sourceDir=%q\n", cfgPath, g.dir)
		}
		fmt.Fprintln(os.Stderr, "提示: 用 -dir/-file 指定书源位置，或运行 legado config gen 生成配置")
		os.Exit(1)
	}
	for _, le := range e.LoadErrors {
		fmt.Fprintln(os.Stderr, "加载警告:", le)
	}
	curEngine = e
	return e
}

func cmdValidate(args []string) {
	fs, g := newFlags("validate")
	online := fs.Bool("online", false, "连网实际校验（搜索/详情/目录/正文）")
	keyword := fs.String("key", "", "在线校验使用的关键字")
	onlyBad := fs.Bool("bad", false, "只输出有问题的书源")
	g.parse(args)

	if !*online {
		var list []*model.BookSource
		var err error
		if g.file != "" {
			list, err = source.LoadFile(g.file)
		} else if g.dir != "" {
			var errs []error
			list, errs = source.LoadDir(g.dir)
			for _, e := range errs {
				fmt.Fprintln(os.Stderr, "加载警告:", e)
			}
		} else {
			fmt.Fprintln(os.Stderr, "请用 -dir 指定书源文件夹或 -file 指定书源文件")
			os.Exit(1)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "错误:", err)
			os.Exit(1)
		}
		bad := 0
		for _, s := range list {
			r := source.Validate(s)
			if *onlyBad && r.OK() {
				continue
			}
			if !r.OK() {
				bad++
			}
			fmt.Printf("── %s <%s>\n", s.BookSourceName, s.BookSourceUrl)
			if len(r.Issues) == 0 {
				fmt.Println("   ✓ 无问题")
			}
			for _, i := range r.Issues {
				mark := "·"
				if i.Level == source.LevelError {
					mark = "✗"
				} else if i.Level == source.LevelWarn {
					mark = "!"
				}
				fmt.Printf("   %s %s\n", mark, i.String())
			}
		}
		fmt.Printf("\n共 %d 个书源，%d 个存在错误\n", len(list), bad)
		if bad > 0 {
			os.Exit(2)
		}
		return
	}

	e := newEngine(g)
	items := source.CheckItems{Search: true, Info: true, Toc: true, Content: true}
	if g.source != "" {
		s := resolveSource(e, g)
		if s == nil {
			os.Exit(1)
		}
		r := source.ValidateOnline(s, *keyword, items)
		printResult(r)
		if !r.OK() {
			os.Exit(2)
		}
		return
	}
	for _, s := range e.Sources {
		r := source.ValidateOnline(s, *keyword, items)
		printResult(r)
	}
}

func printResult(r *source.Result) {
	fmt.Printf("── %s <%s>\n", r.Source.BookSourceName, r.Source.BookSourceUrl)
	for _, i := range r.Issues {
		mark := "·"
		if i.Level == source.LevelError {
			mark = "✗"
		} else if i.Level == source.LevelWarn {
			mark = "!"
		}
		fmt.Printf("   %s %s\n", mark, i.String())
	}
}

func cmdList(args []string) {
	_, g := newFlags("list")
	g.parse(args)
	e := newEngine(g)
	fmt.Printf("共加载 %d 个书源\n", len(e.Sources))
	for i, s := range e.Sources {
		t := "文本"
		switch s.GetBookType() {
		case model.BookTypeAudio:
			t = "音频"
		case model.BookTypeImage:
			t = "图片/漫画"
		case model.BookTypeFile:
			t = "文件"
		}
		fmt.Printf("%3d. %s [%s] %s %s\n", i+1, pad(s.BookSourceName, 26), t, pad(s.BookSourceUrl, 38), s.FileName)
	}
	fmt.Println("\n-source 可用：上面的序号、名称、bookSourceUrl、域名，或最后一列的文件名")
}

func cmdSearch(args []string) {
	fs, g := newFlags("search")
	key := fs.String("key", "", "搜索关键字（必填）")
	page := fs.Int("page", 1, "页码")
	limit := fs.Int("limit", 20, "最多显示条数")
	g.parse(args)
	e := newEngine(g)
	resolveSource(e, g)
	if *key == "" && fs.NArg() > 0 {
		*key = fs.Arg(0)
	}
	if strings.TrimSpace(*key) == "" {
		fmt.Fprintln(os.Stderr, "请用 -key 指定搜索关键字，例如: legado search -dir ./sources -source 漫画客 -key 海贼")
		os.Exit(1)
	}
	list, err := e.Search(g.source, *key, *page)
	if err != nil {
		fmt.Fprintln(os.Stderr, "搜索失败:", err)
		os.Exit(1)
	}
	fmt.Printf("搜索「%s」命中 %d 条\n", *key, len(list))
	for i, b := range list {
		if i >= *limit {
			break
		}
		fmt.Printf("%3d. %-28s %-14s %s\n", i+1, b.Name, b.Author, b.BookUrl)
	}
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
		fmt.Fprintln(os.Stderr, "发现失败:", err)
		os.Exit(1)
	}
	fmt.Printf("发现命中 %d 条\n", len(list))
	for i, b := range list {
		if i >= *limit {
			break
		}
		fmt.Printf("%3d. %-28s %-14s %s\n", i+1, b.Name, b.Author, b.BookUrl)
	}
}

func cmdInfo(args []string) {
	fs, g := newFlags("info")
	bookUrl := fs.String("book", "", "书籍详情页地址")
	name := fs.String("name", "", "书名（书源无 ruleBookInfo 时手动指定）")
	author := fs.String("author", "", "作者")
	g.parse(args)
	if *bookUrl == "" && fs.NArg() > 0 {
		*bookUrl = fs.Arg(0)
	}
	e := newEngine(g)
	resolveSource(e, g)
	book := model.NewBook()
	book.BookUrl = *bookUrl
	book.Origin = g.source
	applyBookMeta(book, *name, *author)
	if err := e.GetBookInfo(g.source, book); err != nil {
		fmt.Fprintln(os.Stderr, "获取详情失败:", err)
		os.Exit(1)
	}
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
	if *bookUrl == "" && fs.NArg() > 0 {
		*bookUrl = fs.Arg(0)
	}
	e := newEngine(g)
	resolveSource(e, g)
	book := model.NewBook()
	book.BookUrl = *bookUrl
	book.Origin = g.source
	applyBookMeta(book, *name, *author)
	if err := e.GetBookInfo(g.source, book); err != nil {
		fmt.Fprintln(os.Stderr, "获取详情失败:", err)
		os.Exit(1)
	}
	chapters, err := e.GetChapterList(g.source, book)
	if err != nil {
		fmt.Fprintln(os.Stderr, "获取目录失败:", err)
		os.Exit(1)
	}
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
	max := fs.Int("len", 800, "预览字数")
	name := fs.String("name", "", "书名（书源无 ruleBookInfo 时手动指定）")
	author := fs.String("author", "", "作者")
	g.parse(args)
	if *bookUrl == "" && fs.NArg() > 0 {
		*bookUrl = fs.Arg(0)
	}
	e := newEngine(g)
	resolveSource(e, g)
	book := model.NewBook()
	book.BookUrl = *bookUrl
	book.Origin = g.source
	applyBookMeta(book, *name, *author)
	if err := e.GetBookInfo(g.source, book); err != nil {
		fmt.Fprintln(os.Stderr, "获取详情失败:", err)
		os.Exit(1)
	}
	chapters, err := e.GetChapterList(g.source, book)
	if err != nil {
		fmt.Fprintln(os.Stderr, "获取目录失败:", err)
		os.Exit(1)
	}
	if *index < 0 || *index >= len(chapters) {
		fmt.Fprintf(os.Stderr, "章节下标越界，目录共 %d 章\n", len(chapters))
		os.Exit(1)
	}
	content, err := e.GetContent(g.source, book, chapters[*index])
	if err != nil {
		fmt.Fprintln(os.Stderr, "获取正文失败:", err)
		os.Exit(1)
	}
	fmt.Printf("── %s（共 %d 字）\n", chapters[*index].Title, len([]rune(content)))
	runes := []rune(content)
	if *max > 0 && len(runes) > *max {
		runes = runes[:*max]
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
	if *bookUrl == "" && fs.NArg() > 0 {
		*bookUrl = fs.Arg(0)
	}
	e := newEngine(g)
	resolveSource(e, g)
	js.OnLog = func(msg string) {
		if g.debug {
			fmt.Fprintln(os.Stderr, msg)
		}
	}
	book := model.NewBook()
	if *bookUrl != "" {
		book.BookUrl = *bookUrl
		book.Origin = g.source
	} else {
		kw := *key
		if kw == "" {
			fmt.Fprintln(os.Stderr, "请指定 -book 或 -key")
			os.Exit(1)
		}
		list, err := e.Search(g.source, kw, 1)
		if err != nil || len(list) == 0 {
			fmt.Fprintln(os.Stderr, "搜索无结果:", err)
			os.Exit(1)
		}
		book = list[0].ToBook()
		fmt.Printf("选中: 《%s》 %s\n", book.Name, book.Author)
	}
	applyBookMeta(book, *name, *author)
	last := 0
	res, err := e.Download(g.source, book, download.Options{
		OutDir:  *out,
		Format:  *format,
		Workers: *workers,
		Max:     *maxCh,
		Start:   *start,
		Progress: func(done, total int, title string) {
			pct := done * 100 / maxInt(total, 1)
			if pct/10 > last/10 || done == total {
				last = done
				fmt.Printf("\r进度 %d%% (%d/%d) %s        ", pct, done, total, title)
			}
		},
	})
	fmt.Println()
	if err != nil {
		fmt.Fprintln(os.Stderr, "下载失败:", err)
		os.Exit(1)
	}
	fmt.Println(res.String())
	_ = e.SaveCookies()
	_ = strconv.Itoa(0)
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

// dispWidth 计算终端显示宽度（中日韩全角字符按 2 列）
func dispWidth(s string) int {
	w := 0
	for _, r := range s {
		switch {
		case r >= 0x1100 && r <= 0x115f, // 谚文字母
			r == 0x2329, r == 0x232a,
			r >= 0x2e80 && r <= 0xa4cf, // CJK 部首、假名、汉字
			r >= 0xac00 && r <= 0xd7a3, // 谚文音节
			r >= 0xf900 && r <= 0xfaff, // CJK 兼容汉字
			r >= 0xfe30 && r <= 0xfe6f, // CJK 兼容形式
			r >= 0xff00 && r <= 0xff60, // 全角形式
			r >= 0xffe0 && r <= 0xffe6:
			w += 2
		default:
			w++
		}
	}
	return w
}

func pad(s string, width int) string {
	if d := dispWidth(s); d < width {
		return s + strings.Repeat(" ", width-d)
	}
	return s
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func firstLine(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	runes := []rune(s)
	if len(runes) > n {
		return string(runes[:n]) + "…"
	}
	return s
}

func usage() {
	fmt.Print(`legado-go —— Legado 书源/漫画源 Go 重构引擎

用法:
  legado <命令> [选项]

命令:
  validate   校验书源语法（-dir/-file，加 -online 连网实测）
  list       列出已加载书源
  search     搜索书籍      -key 关键字
  explore    发现书籍      -url 发现地址
  info       书籍详情      -book 详情页地址
  toc        章节目录      -book 详情页地址
  content    章节正文      -book 详情页地址 -index 下标
  download   下载书籍/漫画  -book 详情页地址 或 -key 关键字
  config     管理 config.json：config gen 生成 / config check 校验

配置（可选）:
  启动时先读配置（默认当前目录 config.json），把其中的值当作各参数默认值，
  再解析命令行；命令行只要写了就覆盖同名配置项。
  优先级：命令行 > config.json > 内置默认。没有 config.json 就用内置默认，不报错。

    legado config gen                                  # 生成默认 config.json
    legado config gen -dir ./sources -source 漫画客     # 生成并预填
    legado config check                                # 校验（含书源能否加载、source 能否命中）
    legado config check -config my.json -json           # 指定文件 + 机器可读输出

book 相关命令通用选项:
  -name     书名（纯发现源没有 ruleBookInfo 时用，否则会以空名保存）
  -author   作者

通用选项（所有命令都可用，默认值取自 config.json）:
  -config <文件>    配置文件路径，默认 config.json；-config= 表示完全不读配置
  -dir <目录>       书源文件夹，递归加载 .json/.txt（配置项 sourceDir）
  -file <文件>      单个书源文件；一个文件可有多个书源（配置项 sourceFile，优先于 -dir）
  -source <key>     用哪个书源，支持 6 种写法（不区分大小写，配置项 source）：
                      1 或 #1        序号，对应 list 输出的第 1 列
                      神奇漫画       书源名称（先全等，再子串）
                      shenqimanhua.net  域名，或完整 bookSourceUrl
                      https://.../comic/1  书籍详情页 URL（按 bookUrlPattern / 域名归属）
                      kantianxia     文件名，带不带 .json 都行
                    留空则用第 1 个书源（有多个时会打印提示）
  -cookie <文件>    Cookie 持久化文件（配置项 cookieFile）；-cookie= 则只存内存
  -cache <文件>     缓存持久化文件（配置项 cacheFile）；-cache= 同理
  -ua <UA>          覆盖默认 User-Agent（配置项 userAgent；书源 header 里的 UA 优先）
  -timeout <秒>     HTTP 超时（配置项 httpTimeout，默认 30）
  -js-timeout <秒>  JS 执行超时（配置项 jsTimeout，默认 30）
  -debug            输出调试日志（配置项 debug，含书源 JS 里 java.log 的内容）

download 专属选项（默认值取自配置项 download.*）:
  -book / -key      详情页地址，或关键字（搜索后取第 1 本）
  -out <目录>       输出目录（download.outDir，默认 ./out）
  -format <格式>    txt | md | images（download.format，留空按书源类型）
  -workers <n>      并发数（download.workers，默认 4）
  -max <n>          最多下载章节数，0 表示全部（download.max）
  -start <n>        起始章节下标（download.start）

示例:
  legado config gen -dir ./sources
  legado list     -dir ./sources
  legado validate -dir ./sources
  legado validate -file ../sources/kantianxia.json -online -source 2
  legado search   -dir ./sources -source 漫画客 -key 海贼
  legado toc      -dir ./sources -source 漫画客 -book http://yumanhua.com/GZxNZae/
  legado download -dir ./sources -source 漫画客 -key 海贼 -out ./out -workers 8
  legado download -dir ./sources -source 漫画客 -book <url> -format images -start 0 -max 5
`)
}
