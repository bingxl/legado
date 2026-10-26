// Package config 管理 legado-go 的 config.json。
//
// config.json 用来存放「每次都要敲一遍」的默认参数（书源目录、默认书源、Cookie 文件、
// 超时、下载目录等）。CLI 的加载顺序是：
//
//	config.json  ←  -config 指定的文件（默认当前目录的 config.json，没有就跳过）
//	             ↓  作为各命令行参数的默认值
//	命令行参数   ←  优先级最高，显式给了就覆盖配置
//
// 库使用者也可以直接 Load 后用 ToRuntime 转成 legado.Config。
package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// FileName 默认配置文件名（相对当前工作目录）
const FileName = "config.json"

// Download 下载相关默认参数，对应 CLI download 命令
type Download struct {
	OutDir  string `json:"outDir"`
	Format  string `json:"format"`
	Workers int    `json:"workers"`
	Max     int    `json:"max"`
	Start   int    `json:"start"`
}

// FileConfig 是 config.json 的结构。
// 字段名用驼峰，与 Legado 的 bookSource JSON 风格保持一致。
type FileConfig struct {
	SourceDir   string   `json:"sourceDir"`   // 书源文件夹，递归加载 .json/.txt
	SourceFile  string   `json:"sourceFile"`  // 单个书源文件，非空时优先于 SourceDir
	Source      string   `json:"source"`      // 默认书源（序号/名称/URL/域名/文件名）
	CookieFile  string   `json:"cookieFile"`  // Cookie 持久化文件，空表示只存内存
	CacheFile   string   `json:"cacheFile"`   // 缓存持久化文件，空表示只存内存
	UserAgent   string   `json:"userAgent"`   // 默认 UA，书源 header 里的 UA 优先
	HTTPTimeout int      `json:"httpTimeout"` // HTTP 超时（秒）
	JSTimeout   int      `json:"jsTimeout"`   // JS 执行超时（秒）
	Debug       bool     `json:"debug"`       // 输出调试日志
	Download    Download `json:"download"`    // 下载默认参数

	// unknown 记录 JSON 里出现但结构体不认识的字段，供 Validate 报「疑似拼错」
	unknown []string
	// path 为 Load 时的来源路径，仅用于报错信息
	path string
}

// Default 返回内置默认配置
func Default() *FileConfig {
	return &FileConfig{
		SourceDir:   "./sources",
		CookieFile:  "cookies.json",
		CacheFile:   "cache.json",
		HTTPTimeout: 30,
		JSTimeout:   30,
		Download: Download{
			OutDir:  "./out",
			Workers: 4,
		},
	}
}

// Path 返回配置来源文件路径（Load 之后才有值）
func (c *FileConfig) Path() string { return c.path }

// UnknownFields 返回 JSON 中出现但未识别的字段名
func (c *FileConfig) UnknownFields() []string { return c.unknown }

// Load 读取配置文件。文件里的缺省字段会保留 Default() 的值，
// 因此只需在 config.json 里写想改的项。
// 路径为空或文件不存在时返回 os.ErrNotExist（调用方可据此决定是否忽略）。
func Load(path string) (*FileConfig, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	c := Default()
	c.path = path
	// 先按宽松方式解码，语法/类型错误直接报；未知字段留给 Validate 提示
	if err := json.Unmarshal(b, c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	c.unknown = detectUnknown(b)
	return c, nil
}

// Unmarshal 从字节解析（供测试与内存配置使用）
func Unmarshal(b []byte) (*FileConfig, error) {
	c := Default()
	if err := json.Unmarshal(b, c); err != nil {
		return nil, err
	}
	c.unknown = detectUnknown(b)
	return c, nil
}

// Encode 序列化为美观的 JSON（2 空格缩进 + 结尾换行）
func (c *FileConfig) Encode() ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(c); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Save 写入文件；force=false 且文件已存在时报错，避免覆盖手写配置
func (c *FileConfig) Save(path string, force bool) error {
	if !force {
		if _, err := os.Stat(path); err == nil {
			return fmt.Errorf("%s 已存在（用 -force 覆盖）", path)
		}
	}
	b, err := c.Encode()
	if err != nil {
		return err
	}
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		return err
	}
	c.path = path
	return nil
}

// Normalize 把零值收敛成安全默认，供实际运行使用。
// 在 Validate 之后调用：Validate 看的是用户原值，Normalize 产出可直接跑的配置。
func (c *FileConfig) Normalize() {
	if c.HTTPTimeout <= 0 {
		c.HTTPTimeout = 30
	}
	if c.JSTimeout <= 0 {
		c.JSTimeout = 30
	}
	if strings.TrimSpace(c.Download.OutDir) == "" {
		c.Download.OutDir = "./out"
	}
	if c.Download.Workers <= 0 {
		c.Download.Workers = 4
	}
	if c.Download.Workers > 64 {
		c.Download.Workers = 64
	}
	c.SourceDir = strings.TrimSpace(c.SourceDir)
	c.SourceFile = strings.TrimSpace(c.SourceFile)
	c.Source = strings.TrimSpace(c.Source)
	c.CookieFile = strings.TrimSpace(c.CookieFile)
	c.CacheFile = strings.TrimSpace(c.CacheFile)
	c.UserAgent = strings.TrimSpace(c.UserAgent)
	c.Download.Format = strings.ToLower(strings.TrimSpace(c.Download.Format))
}

// ---------- 校验 ----------

// Level 问题级别
type Level int

const (
	LevelInfo Level = iota
	LevelWarn
	LevelError
)

func (l Level) String() string {
	switch l {
	case LevelError:
		return "错误"
	case LevelWarn:
		return "警告"
	default:
		return "提示"
	}
}

// Issue 一条校验结果
type Issue struct {
	Level Level
	Field string
	Msg   string
}

func (i Issue) String() string {
	if i.Field == "" {
		return i.Msg
	}
	return i.Field + ": " + i.Msg
}

// Result 校验结果集合
type Result struct {
	Path   string
	Issues []Issue
}

// OK 没有错误
func (r *Result) OK() bool {
	for _, i := range r.Issues {
		if i.Level == LevelError {
			return false
		}
	}
	return true
}

// Count 按级别计数
func (r *Result) Count() (errs, warns, infos int) {
	for _, i := range r.Issues {
		switch i.Level {
		case LevelError:
			errs++
		case LevelWarn:
			warns++
		default:
			infos++
		}
	}
	return
}

// ValidSource 书源加载结果的回调：把已加载的书源交给调用方做 source 匹配校验。
// 返回 nil 表示调用方不关心（例如只做静态检查）。
type ValidSource func(c *FileConfig) []Issue

// Validate 校验配置。sourceCheck 可为 nil；CLI 会传入「加载书源并匹配 source」的检查。
func (c *FileConfig) Validate(sourceCheck ValidSource) *Result {
	r := &Result{Path: c.path}
	add := func(lv Level, field, msg string) {
		r.Issues = append(r.Issues, Issue{lv, field, msg})
	}

	// 未知字段（多半是拼写错误）
	for _, f := range c.unknown {
		if s := SuggestField(f); s != "" {
			add(LevelWarn, f, "未知字段，是否想写 "+s+"？")
		} else {
			add(LevelWarn, f, "未知字段，将被忽略")
		}
	}

	// 书源来源
	if c.SourceDir == "" && c.SourceFile == "" {
		add(LevelError, "sourceDir", "sourceDir 与 sourceFile 都为空，无法加载书源")
	}
	if c.SourceDir != "" {
		if fi, err := os.Stat(c.SourceDir); err != nil {
			add(LevelError, "sourceDir", "目录不存在: "+c.SourceDir)
		} else if !fi.IsDir() {
			add(LevelError, "sourceDir", "不是目录: "+c.SourceDir)
		}
	}
	if c.SourceFile != "" {
		if fi, err := os.Stat(c.SourceFile); err != nil {
			add(LevelError, "sourceFile", "文件不存在: "+c.SourceFile)
		} else if fi.IsDir() {
			add(LevelError, "sourceFile", "是目录，应该写进 sourceDir: "+c.SourceFile)
		}
		if c.SourceDir != "" {
			add(LevelInfo, "sourceFile", "非空，运行时优先于 sourceDir（sourceDir 被忽略）")
		}
	}

	// 超时
	checkInt := func(field string, v, min, max, def int, unit string) {
		switch {
		case v < 0:
			add(LevelError, field, fmt.Sprintf("%d%s 不能为负数", v, unit))
		case v == 0:
			add(LevelInfo, field, fmt.Sprintf("为 0（视为未设置），运行时使用默认 %d%s", def, unit))
		case v < min:
			add(LevelWarn, field, fmt.Sprintf("%d%s 偏小，建议 >= %d%s", v, unit, min, unit))
		case v > max:
			add(LevelWarn, field, fmt.Sprintf("%d%s 偏大，建议 <= %d%s", v, unit, max, unit))
		}
	}
	checkInt("httpTimeout", c.HTTPTimeout, 5, 600, 30, "秒")
	checkInt("jsTimeout", c.JSTimeout, 1, 600, 30, "秒")

	// 存储文件：writeJSONFile 会自动建父目录，只提示「不落盘」
	if c.CookieFile == "" {
		add(LevelInfo, "cookieFile", "为空，Cookie 仅保存在内存（进程结束即丢）")
	}
	if c.CacheFile == "" {
		add(LevelInfo, "cacheFile", "为空，缓存仅保存在内存")
	}

	// UA 不能带换行，否则会拼坏请求头
	if strings.ContainsAny(c.UserAgent, "\r\n") {
		add(LevelError, "userAgent", "不能包含换行符")
	}

	// 下载参数
	dl := c.Download
	switch dl.Format {
	case "", "txt", "md", "images":
	default:
		add(LevelError, "download.format", "只能是 txt / md / images（或留空按书源类型）")
	}
	if dl.Workers < 0 {
		add(LevelError, "download.workers", "不能为负数")
	} else if dl.Workers == 0 {
		add(LevelInfo, "download.workers", "为 0（视为未设置），运行时使用默认 4")
	} else if dl.Workers > 64 {
		add(LevelWarn, "download.workers", fmt.Sprintf("%d 偏高，建议 <= 64，否则容易被站点限流", dl.Workers))
	}
	if dl.Max < 0 {
		add(LevelError, "download.max", "不能为负数（0 表示全部）")
	}
	if dl.Start < 0 {
		add(LevelError, "download.start", "不能为负数")
	}
	if dl.OutDir == "" {
		add(LevelInfo, "download.outDir", "为空，默认 ./out")
	}

	// 用真实书源验证 source 写法能否命中
	if sourceCheck != nil {
		r.Issues = append(r.Issues, sourceCheck(c)...)
	}
	return r
}

// ---------- 字段元数据 ----------

// Field 配置字段说明
type Field struct {
	Name string
	Type string
	Desc string
}

// Fields 全部配置字段，按文件中的书写顺序排列
var Fields = []Field{
	{"sourceDir", "string", "书源文件夹，递归加载 .json/.txt"},
	{"sourceFile", "string", "单个书源文件；非空时优先于 sourceDir"},
	{"source", "string", "默认书源：序号(1) | 名称 | bookSourceUrl | 域名 | 详情页 URL | 文件名"},
	{"cookieFile", "string", "Cookie 持久化文件；留空表示只存内存"},
	{"cacheFile", "string", "缓存持久化文件；留空表示只存内存"},
	{"userAgent", "string", "默认 User-Agent；书源 header 里写了 UA 时以书源为准"},
	{"httpTimeout", "int", "HTTP 超时（秒），默认 30"},
	{"jsTimeout", "int", "JS 执行超时（秒），默认 30"},
	{"debug", "bool", "输出调试日志（含书源 JS 里的 java.log）"},
	{"download.outDir", "string", "下载输出目录，默认 ./out"},
	{"download.format", "string", "txt | md | images，留空按书源类型自动判断"},
	{"download.workers", "int", "并发章节数，默认 4（建议 1~16）"},
	{"download.max", "int", "最多下载章节数，0 表示全部"},
	{"download.start", "int", "起始章节下标，0 表示第一章"},
}

// FieldDocs 生成「字段 / 类型 / 说明」对齐的文本，供 CLI 帮助使用
func FieldDocs() string {
	var sb strings.Builder
	w1, w2 := 0, 0
	for _, f := range Fields {
		if n := dispWidth(f.Name); n > w1 {
			w1 = n
		}
		if n := dispWidth(f.Type); n > w2 {
			w2 = n
		}
	}
	for _, f := range Fields {
		fmt.Fprintf(&sb, "  %s  %s  %s\n",
			padRight(f.Name, w1), padRight(f.Type, w2), f.Desc)
	}
	return sb.String()
}

// SuggestField 对未知字段做近似匹配，返回最可能的正确字段名（无合适候选返回空）
func SuggestField(name string) string {
	norm := func(s string) string {
		s = strings.ToLower(s)
		return strings.NewReplacer("-", "", "_", "", ".", "", " ", "").Replace(s)
	}
	n := norm(name)
	best, bestD := "", 0
	for _, f := range Fields {
		d := levenshtein(n, norm(f.Name))
		if d > 1 { // 只接受 1 个字符以内的差异，避免乱猜
			continue
		}
		if d == 0 {
			return f.Name
		}
		if best == "" || d < bestD {
			best, bestD = f.Name, d
		}
	}
	return best
}

// detectUnknown 找出 JSON 中未定义的键（含 download 子对象）
func detectUnknown(b []byte) []string {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(b, &top); err != nil {
		return nil
	}
	known := map[string]string{ // 顶层字段 -> 子对象名（空表示叶子）；键区分大小写
		"sourceDir": "", "sourceFile": "", "source": "",
		"cookieFile": "", "cacheFile": "", "userAgent": "",
		"httpTimeout": "", "jsTimeout": "", "debug": "",
		"download": "download",
	}
	var out []string
	for k, raw := range top {
		val, ok := known[k]
		if !ok {
			out = append(out, k)
			continue
		}
		if val != "download" {
			continue
		}
		var sub map[string]json.RawMessage
		if err := json.Unmarshal(raw, &sub); err != nil {
			continue
		}
		for sk := range sub {
			switch sk {
			case "outDir", "format", "workers", "max", "start":
			default:
				out = append(out, "download."+sk)
			}
		}
	}
	sort.Strings(out)
	return out
}

func levenshtein(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	if len(ra) == 0 {
		return len(rb)
	}
	if len(rb) == 0 {
		return len(ra)
	}
	prev := make([]int, len(rb)+1)
	cur := make([]int, len(rb)+1)
	for j := 0; j <= len(rb); j++ {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		cur[0] = i
		for j := 1; j <= len(rb); j++ {
			cost := 1
			if ra[i-1] == rb[j-1] {
				cost = 0
			}
			cur[j] = min3(cur[j-1]+1, prev[j]+1, prev[j-1]+cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(rb)]
}

func min3(a, b, c int) int {
	if b < a {
		a = b
	}
	if c < a {
		a = c
	}
	return a
}

// dispWidth 终端显示宽度（全角按 2 列）
func dispWidth(s string) int {
	w := 0
	for _, r := range s {
		switch {
		case r >= 0x1100 && r <= 0x115f,
			r == 0x2329, r == 0x232a,
			r >= 0x2e80 && r <= 0xa4cf,
			r >= 0xac00 && r <= 0xd7a3,
			r >= 0xf900 && r <= 0xfaff,
			r >= 0xfe30 && r <= 0xfe6f,
			r >= 0xff00 && r <= 0xff60,
			r >= 0xffe0 && r <= 0xffe6:
			w += 2
		default:
			w++
		}
	}
	return w
}

func padRight(s string, width int) string {
	if d := dispWidth(s); d < width {
		return s + strings.Repeat(" ", width-d)
	}
	return s
}
