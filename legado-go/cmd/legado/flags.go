package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/legado/legado-go"
	"github.com/legado/legado-go/pkg/config"
)

var (
	// curEngine 当前引擎，供退出前统一落盘 Cookie
	curEngine *legado.Engine
	// baseCfg 是 config.json 解析出的默认值，作为各命令行参数的默认值
	baseCfg = config.Default()
	// cfgPath 是本次实际使用的配置文件路径（空表示不使用配置文件）
	cfgPath = config.FileName
)

// globalFlags 是所有子命令共用的选项
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
	fs.Usage = func() { printFlagUsage(fs, name) }

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
	set := visitedFlags(g.fs)
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

// visitedFlags 返回命令行上显式出现过的参数名集合
func visitedFlags(fs *flag.FlagSet) map[string]bool {
	set := make(map[string]bool)
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	return set
}

// argOr 用第 1 个位置参数补全空值（如 toc <bookUrl> 与 toc -book <bookUrl> 等价）
func argOr(fs *flag.FlagSet, v *string) {
	if *v == "" && fs.NArg() > 0 {
		*v = fs.Arg(0)
	}
}

// scanConfigPath 在子命令参数里预扫描 -config。
// 必须早于 flag 解析：各命令参数的默认值要来自配置，而配置路径本身也是参数。
func scanConfigPath(args []string) (path string, explicit bool) {
	for i, a := range args {
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

// loadConfig 按子命令参数预扫描并读取配置，失败时给出定位建议后退出
func loadConfig(args []string) {
	path, explicit := scanConfigPath(args)
	if err := initConfig(path, explicit); err != nil {
		fmt.Fprintln(os.Stderr, "读取配置失败:", configErrText(path, err))
		if !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintln(os.Stderr, "（用 -config= 可跳过配置；legado config check 可定位问题）")
		}
		os.Exit(1)
	}
}

// newEngine 按解析后的选项建引擎；加载失败时打印定位信息并退出
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
