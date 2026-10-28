package main

import (
	"fmt"
	"os"
	"strings"
)

// command 描述一个子命令
type command struct {
	run func(args []string)
	// withoutConfig 表示该命令自己处理配置文件，启动时不预加载 config.json
	withoutConfig bool
}

// commands 是命令表：新增命令只需在这里登记，main 不再堆 if/switch
var commands = map[string]command{
	"validate":     {run: cmdValidate},
	"check":        {run: cmdValidate},
	"list":         {run: cmdList},
	"sources":      {run: cmdList},
	"search":       {run: cmdSearch},
	"explore":      {run: cmdExplore},
	"info":         {run: cmdInfo},
	"toc":          {run: cmdToc},
	"content":      {run: cmdContent},
	"download":     {run: cmdDownload},
	"debug":        {run: cmdDebug},
	"config":       {run: cmdConfig, withoutConfig: true},
	"config-gen":   {run: cmdConfigGen, withoutConfig: true},
	"config-check": {run: cmdConfigCheckCmd, withoutConfig: true},
}

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
	name, args := os.Args[1], os.Args[2:]

	// 帮助与误用（把全局选项写在命令前面）都在查表之前拦掉
	switch {
	case isHelpArg(name):
		usage()
		return
	case strings.HasPrefix(name, "-"):
		fmt.Fprintf(os.Stderr, "全局选项要写在命令后面，例如: legado list -config my.json\n\n")
		usage()
		os.Exit(1)
	}

	c, ok := commands[name]
	if !ok {
		fmt.Fprintf(os.Stderr, "未知命令: %s\n\n", name)
		usage()
		os.Exit(1)
	}

	// 第一步：读配置（-config 指定的，或当前目录的 config.json）
	// 第二步：各命令解析命令行，同名参数覆盖配置
	if !c.withoutConfig {
		loadConfig(args)
	}
	c.run(args)
}

// isHelpArg 判断参数是否为帮助请求
func isHelpArg(s string) bool {
	switch strings.ToLower(s) {
	case "help", "-h", "-help", "--help":
		return true
	}
	return false
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
  debug      书源调试      -key 入口（关键字/URL/分类::地址/++目录/--正文），逐步打印请求与规则求值
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

debug 专属选项（对齐客户端「书源调试」，-key 为空时打印详细用法）:
  -key <入口>       海贼王=搜索 | https://...=详情页 | 分类::地址=发现页
                    ++https://.../toc=目录页 | --https://.../c1=正文页
  -stage <阶段>     all|search|explore|info|toc|content，跑到哪一步停（默认 all）
  -body <方式>      none|head|full，响应体怎么输出（默认 none，只给摘要）
  -body-limit <n>   -body head 的截断字节数（默认 2048）
  -save-dir <目录>  把 search/info/toc/content 响应体另存成文件
  -max-chars <n>    单条日志最大字数（默认 0 不限制，正文很长时用它压一压）
  -json             日志按 JSONL 输出，便于管道处理
  -o <文件>         日志写入文件（默认 stdout）
  -color <模式>     auto|always|never（auto 在 Windows 下不着色）

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
