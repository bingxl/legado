package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/legado/legado-go/pkg/config"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/source"
)

// configErrText 把配置文件读取错误转成中文提示
func configErrText(path string, err error) string {
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Sprintf("配置文件不存在: %s（用 legado config gen 生成，或用 -config= 跳过配置）", path)
	}
	return err.Error()
}

// cmdConfig 处理 config 子命令：gen（生成）/ check（校验）
func cmdConfig(args []string) {
	sub := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		sub = args[0]
		args = args[1:]
	}
	switch sub {
	case "gen", "generate", "init", "new":
		cmdConfigGen(args)
	case "check", "validate", "verify":
		cmdConfigCheck(args, true)
	case "":
		// 没有子命令：配置文件存在就校验，否则给出引导
		path, _ := scanConfigPath(args)
		if path != "" {
			if _, err := os.Stat(path); err == nil {
				cmdConfigCheck([]string{"-config", path}, true)
				return
			}
		}
		fmt.Println("config.json 不存在。可用：")
		fmt.Println("  legado config gen                 # 生成默认 config.json")
		fmt.Println("  legado config gen -dir ./sources  # 生成并指定书源目录")
		fmt.Println("  legado config check               # 校验 config.json")
		fmt.Println("\n配置项说明：")
		fmt.Print(config.FieldDocs())
	case "path", "show":
		p, _ := scanConfigPath(args)
		fmt.Println(p)
	default:
		fmt.Fprintf(os.Stderr, "未知 config 子命令: %s\n可用: gen | check\n", sub)
		os.Exit(1)
	}
}

func cmdConfigGen(args []string) {
	fs := flag.NewFlagSet("config gen", flag.ExitOnError)
	out := fs.String("out", config.FileName, "生成到哪个文件（-out - 输出到终端）")
	force := fs.Bool("force", false, "文件已存在时覆盖")
	dir := fs.String("dir", "", "写入 sourceDir（默认 ./sources）")
	file := fs.String("file", "", "写入 sourceFile（单个书源文件）")
	src := fs.String("source", "", "写入默认书源（序号/名称/URL/域名/文件名）")
	cookie := fs.String("cookie", "", "写入 cookieFile")
	cache := fs.String("cache", "", "写入 cacheFile")
	ua := fs.String("ua", "", "写入 userAgent")
	timeout := fs.Int("timeout", 0, "写入 httpTimeout（秒）")
	jsTime := fs.Int("js-timeout", 0, "写入 jsTimeout（秒）")
	debug := fs.Bool("debug-output", false, "写入 debug=true")
	outDir := fs.String("out-dir", "", "写入 download.outDir")
	workers := fs.Int("workers", 0, "写入 download.workers")
	docs := fs.Bool("docs", false, "同时打印每项配置的含义")
	_ = fs.Parse(args)

	c := config.Default()
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	if set["dir"] {
		c.SourceDir = *dir
	}
	if set["file"] {
		c.SourceFile = *file
	}
	if set["source"] {
		c.Source = *src
	}
	if set["cookie"] {
		c.CookieFile = *cookie
	}
	if set["cache"] {
		c.CacheFile = *cache
	}
	if set["ua"] {
		c.UserAgent = *ua
	}
	if *timeout > 0 {
		c.HTTPTimeout = *timeout
	}
	if *jsTime > 0 {
		c.JSTimeout = *jsTime
	}
	if *debug {
		c.Debug = true
	}
	if *outDir != "" {
		c.Download.OutDir = *outDir
	}
	if *workers > 0 {
		c.Download.Workers = *workers
	}
	c.Normalize()

	if *out == "-" {
		b, err := c.Encode()
		if err != nil {
			fmt.Fprintln(os.Stderr, "序列化失败:", err)
			os.Exit(1)
		}
		os.Stdout.Write(b)
		return
	}
	if err := c.Save(*out, *force); err != nil {
		fmt.Fprintln(os.Stderr, "生成失败:", err)
		os.Exit(1)
	}
	fmt.Printf("已生成 %s\n", *out)
	fmt.Printf("  sourceDir: %s  cookieFile: %s  cacheFile: %s\n", c.SourceDir, c.CookieFile, c.CacheFile)
	fmt.Println("  之后所有命令都会默认读取它，命令行参数可覆盖任意一项；用 -config 指定其它文件，-config= 可关闭。")
	if *docs {
		fmt.Println("\n配置项说明：")
		fmt.Print(config.FieldDocs())
	}
}

func cmdConfigCheck(args []string, report bool) {
	fs := flag.NewFlagSet("config check", flag.ExitOnError)
	path := fs.String("config", config.FileName, "要校验的配置文件")
	asJSON := fs.Bool("json", false, "以 JSON 输出结果")
	_ = fs.Parse(args)

	if *path == "" {
		fmt.Fprintln(os.Stderr, "已用 -config= 关闭配置，无需校验")
		os.Exit(1)
	}
	c, err := config.Load(*path)
	if err != nil {
		msg := configErrText(*path, err)
		if report {
			fmt.Fprintln(os.Stderr, "✗ "+msg)
		}
		if *asJSON {
			printIssuesJSON([]config.Issue{{Level: config.LevelError, Field: "", Msg: msg}})
		}
		os.Exit(2)
	}
	r := c.Validate(checkSourceConfig)
	if *asJSON {
		printIssuesJSON(r.Issues)
		if !r.OK() {
			os.Exit(2)
		}
		return
	}
	if !report {
		return
	}
	fmt.Printf("检查 %s\n", *path)
	for _, i := range r.Issues {
		mark := "·"
		switch i.Level {
		case config.LevelError:
			mark = "✗"
		case config.LevelWarn:
			mark = "!"
		}
		fmt.Printf("   %s %s\n", mark, i.String())
	}
	if len(r.Issues) == 0 {
		fmt.Println("   ✓ 无问题")
	}
	errs, warns, _ := r.Count()
	fmt.Printf("\n共 %d 个错误，%d 个警告\n", errs, warns)
	if !r.OK() {
		os.Exit(2)
	}
}

func printIssuesJSON(issues []config.Issue) {
	type item struct {
		Level string `json:"level"`
		Field string `json:"field,omitempty"`
		Msg   string `json:"msg"`
	}
	out := struct {
		OK     bool   `json:"ok"`
		Issues []item `json:"issues"`
	}{OK: true}
	for _, i := range issues {
		lv := "info"
		switch i.Level {
		case config.LevelError:
			lv = "error"
			out.OK = false
		case config.LevelWarn:
			lv = "warn"
		}
		out.Issues = append(out.Issues, item{lv, i.Field, i.Msg})
	}
	if out.Issues == nil {
		out.Issues = []item{}
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false) // 别把 <= 转成 \u003c=
	_ = enc.Encode(out)
}

// checkSourceConfig 用真实书源验证 sourceDir/sourceFile/source 三项是否可用
func checkSourceConfig(c *config.FileConfig) []config.Issue {
	var out []config.Issue
	add := func(lv config.Level, field, msg string) {
		out = append(out, config.Issue{Level: lv, Field: field, Msg: msg})
	}

	var list []*model.BookSource
	switch {
	case c.SourceFile != "":
		if fi, err := os.Stat(c.SourceFile); err != nil || fi.IsDir() {
			return out // 前面的来源检查已报错，不重复
		}
		l, err := source.LoadFile(c.SourceFile)
		if err != nil {
			add(config.LevelError, "sourceFile", "加载失败: "+err.Error())
			return out
		}
		list = l
	case c.SourceDir != "":
		if fi, err := os.Stat(c.SourceDir); err != nil || !fi.IsDir() {
			return out
		}
		l, errs := source.LoadDir(c.SourceDir)
		list = l
		for _, e := range errs {
			add(config.LevelWarn, "sourceDir", "部分文件加载失败: "+e.Error())
		}
	default:
		return out
	}

	if len(list) == 0 {
		add(config.LevelError, "sources", "没有加载到任何书源")
		return out
	}
	add(config.LevelInfo, "sources", fmt.Sprintf("已加载 %d 个书源", len(list)))

	if c.Source == "" {
		add(config.LevelInfo, "source", fmt.Sprintf("未设置，运行时使用第 1 个（%s）", list[0].BookSourceName))
		return out
	}
	m := source.MatchAll(list, c.Source)
	switch len(m) {
	case 0:
		add(config.LevelError, "source", fmt.Sprintf("%q 无法匹配任何书源\n%s",
			c.Source, source.HintNotFound(list)))
	case 1:
		add(config.LevelInfo, "source", fmt.Sprintf("%q → %s <%s>", c.Source, m[0].BookSourceName, m[0].BookSourceUrl))
	default:
		names := make([]string, 0, len(m))
		for _, s := range m {
			names = append(names, s.BookSourceName)
		}
		add(config.LevelWarn, "source", fmt.Sprintf("%q 匹配到 %d 个书源，将使用「%s」；候选: %s",
			c.Source, len(m), m[0].BookSourceName, strings.Join(names, " / ")))
	}
	return out
}
