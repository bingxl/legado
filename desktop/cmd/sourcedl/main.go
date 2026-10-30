// Command sourcedl 从书源下载书籍并导出为 TXT，用于端到端验证书源链路。
//
// 它复用与图形界面完全相同的依赖装配（internal/bootstrap），
// 因此这里跑通的链路等价于应用内跑通的链路。
//
// 用法：
//
//	sourcedl import   -file <书源文件或 URL>
//	sourcedl list
//	sourcedl check    [-limit N]          校验书源可用性，找出真正能用的源
//	sourcedl search   -source <id> -kw <关键词>
//	sourcedl explore  [-source <id>] [-url 分类地址] [-page N]
//	sourcedl download -source <id> -kw <关键词> [-pick N] [-chapters N] [-out <目录>]
//
// 数据目录默认在系统临时目录下，可用 -home 覆盖以便保留结果。
// 退出码：0 成功，1 失败。
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/legado/desktop/internal/adapter/eventlog"
	"github.com/legado/desktop/internal/adapter/exporter"
	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/bootstrap"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// downloadUA 与站点交互时使用的 UA，书源常据此返回桌面版页面。
const downloadUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "错误: %v\n", err)
		os.Exit(1)
	}
}

// run 解析子命令、装配依赖并执行。
func run(args []string) error {
	home, rest := splitGlobal(args)
	if len(rest) == 0 {
		usage()
		return fmt.Errorf("缺少子命令")
	}
	cmd, rest := rest[0], rest[1:]

	biz, err := bootstrap.New(home, eventlog.New(os.Stdout))
	if err != nil {
		return err
	}
	defer biz.Close() //nolint:errcheck

	switch cmd {
	case "import":
		return cmdImport(biz, rest)
	case "list":
		return cmdList(biz)
	case "check":
		return cmdCheck(biz, rest)
	case "search":
		return cmdSearch(biz, rest)
	case "explore":
		return cmdExplore(biz, rest)
	case "download":
		return cmdDownload(biz, rest)
	default:
		usage()
		return fmt.Errorf("未知子命令: %s", cmd)
	}
}

// defaultHome 是未指定 -home 时使用的数据目录。
func defaultHome() string {
	return filepath.Join(os.TempDir(), "sourcedl")
}

// splitGlobal 从任意位置提取全局选项 -home，返回其值与其余参数。
//
// 之所以自己扫描而不是用 flag 预解析：flag 遇到第一个非选项参数就停止，
// 无法同时支持 "sourcedl -home d list" 与 "sourcedl list -home d" 两种写法。
func splitGlobal(args []string) (home string, rest []string) {
	home = defaultHome()
	rest = make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-home" || a == "--home":
			if i+1 < len(args) {
				home = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "-home="):
			home = strings.TrimPrefix(a, "-home=")
		case strings.HasPrefix(a, "--home="):
			home = strings.TrimPrefix(a, "--home=")
		default:
			rest = append(rest, a)
		}
	}
	return home, rest
}

// usage 打印用法说明。
func usage() {
	fmt.Println(`用法:
  sourcedl [-home 数据目录] import   -file <书源文件或 URL>
  sourcedl [-home 数据目录] list
  sourcedl [-home 数据目录] check    [-limit N]
  sourcedl [-home 数据目录] search   -source <id> -kw <关键词>
  sourcedl [-home 数据目录] explore  [-source <id>] [-url 分类地址] [-page N]
  sourcedl [-home 数据目录] download -source <id> -kw <关键词> [-pick N] [-chapters N] [-out 目录]`)
}

// cmdImport 导入书源：支持本地文件路径或 http(s) URL。
func cmdImport(biz *bootstrap.App, args []string) error {
	fs := flag.NewFlagSet("import", flag.ContinueOnError)
	file := fs.String("file", "", "书源 JSON 文件路径或 URL")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *file == "" {
		return fmt.Errorf("需要 -file")
	}

	data, err := readSource(*file)
	if err != nil {
		return err
	}

	res, err := biz.Source.Import(context.Background(), data, true)
	if err != nil {
		return err
	}
	fmt.Printf("导入完成: 新增 %d，更新 %d，跳过 %d，失败 %d\n",
		res.Imported, res.Updated, res.Skipped, len(res.Failures))
	for _, f := range res.Failures {
		fmt.Printf("  ! %s (%s): %s\n", f.Name, f.URL, f.Reason)
	}
	return nil
}

// readSource 读取书源内容，支持本地路径与 URL。
func readSource(src string) ([]byte, error) {
	if strings.HasPrefix(src, "http://") || strings.HasPrefix(src, "https://") {
		return fetchURL(src)
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return nil, fmt.Errorf("读取书源文件失败: %w", err)
	}
	return data, nil
}

// cmdList 列出已导入的书源。
func cmdList(biz *bootstrap.App) error {
	list, err := biz.Source.List(context.Background(), "")
	if err != nil {
		return err
	}
	if len(list) == 0 {
		fmt.Println("(书源为空，先执行 import)")
		return nil
	}
	fmt.Printf("共 %d 个书源:\n", len(list))
	for _, s := range list {
		state := "禁用"
		if s.Enabled {
			state = "启用"
		}
		fmt.Printf("  [%3d] %-30s %-4s %s\n", s.ID, truncate(s.Name, 30), state, s.URL)
	}
	return nil
}

// cmdCheck 校验书源，输出哪些源真正可用。
func cmdCheck(biz *bootstrap.App, args []string) error {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	limit := fs.Int("limit", 12, "最多校验多少个书源")
	quick := fs.Bool("quick", false, "只校验搜索（默认走完搜索→详情→目录→正文全链路）")
	if err := fs.Parse(args); err != nil {
		return err
	}

	list, err := biz.Source.List(context.Background(), "")
	if err != nil {
		return err
	}
	if len(list) == 0 {
		return fmt.Errorf("书源为空，先执行 import")
	}
	if *limit > 0 && len(list) > *limit {
		list = list[:*limit]
	}

	ids := make([]int64, 0, len(list))
	for _, s := range list {
		ids = append(ids, s.ID)
	}

	// 只测搜索会把「能搜到但正文抓不到」的源判为可用；
	// 默认跑全链路，才能回答「这个源能不能真的下载一本书」。
	items := port.CheckAll()
	if *quick {
		items = port.CheckItems{Search: true}
	}

	scope := "全链路（搜索→详情→目录→正文）"
	if *quick {
		scope = "仅搜索"
	}
	fmt.Printf("开始校验 %d 个书源，范围：%s，耗时取决于网络...\n", len(ids), scope)
	start := time.Now()
	results, err := biz.Source.Validate(context.Background(), ids, items)
	if err != nil {
		return err
	}
	fmt.Printf("校验完成，耗时 %s\n\n", time.Since(start).Round(time.Millisecond))

	var usable int
	for _, r := range results {
		if r.OK {
			usable++
			fmt.Printf("  OK   [%3d] %-24s %s\n", r.SourceID, truncate(r.SourceName, 24), summarizeIssues(r.Issues))
			continue
		}
		fmt.Printf("  FAIL [%3d] %-24s %s\n", r.SourceID, truncate(r.SourceName, 24), firstMessage(r.Issues))
	}
	fmt.Printf("\n可用 %d / %d（其余多为站点不可达、反爬或已改版）\n", usable, len(results))
	return nil
}

// summarizeIssues 把校验结果压缩成一行，便于扫读。
//
// 只展示 error/warning，info 里的「正文 N 字」是判定可用的关键信息，单独取。
func summarizeIssues(in []dto.ValidationIssue) string {
	var warnings, content string
	for _, i := range in {
		switch strings.ToLower(i.Level) {
		case "error":
			return i.Message
		case "warning":
			if warnings == "" {
				warnings = i.Message
			}
		case "info":
			if strings.HasPrefix(i.Message, "正文解析成功") {
				content = i.Message
			}
		}
	}
	if content == "" {
		content = "正文未校验"
	}
	if warnings != "" {
		return warnings + " / " + content
	}
	return content
}

// cmdSearch 搜索书籍，可指定单个书源或全部启用书源。
func cmdSearch(biz *bootstrap.App, args []string) error {
	fs := flag.NewFlagSet("search", flag.ContinueOnError)
	sourceID := fs.Int64("source", 0, "书源 ID（0 表示搜索全部启用源）")
	kw := fs.String("kw", "", "搜索关键词")
	limit := fs.Int("limit", 10, "最多显示多少条")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *kw == "" {
		return fmt.Errorf("需要 -kw")
	}

	ctx := context.Background()
	var list []dto.SearchResultView
	var err error
	if *sourceID == 0 {
		list, err = biz.Source.SearchAll(ctx, *kw, 1)
	} else {
		list, err = biz.Source.Search(ctx, *sourceID, *kw, 1)
	}
	if err != nil {
		return err
	}
	if len(list) == 0 {
		fmt.Println("(没有搜索结果)")
		return nil
	}
	if *limit > 0 && len(list) > *limit {
		list = list[:*limit]
	}
	fmt.Printf("搜索 %q 得到 %d 条:\n", *kw, len(list))
	for _, r := range list {
		fmt.Printf("  %-32s 作者:%-14s 源:%-16s\n      %s\n",
			truncate(r.Name, 32), truncate(r.Author, 14), truncate(r.OriginName, 16), r.BookURL)
	}
	return nil
}

// cmdExplore 列出支持「发现」的书源，或拉取某个分类下的书单。
//
// 不带 -source 时只列出「哪些源能发现、各有哪些分类」，用于确认分类解析正确；
// 带 -source 时真正发起请求，验证发现页的书单解析。
func cmdExplore(biz *bootstrap.App, args []string) error {
	fs := flag.NewFlagSet("explore", flag.ContinueOnError)
	sourceID := fs.Int64("source", 0, "书源 ID（0 表示只列出可发现的书源）")
	url := fs.String("url", "", "分类地址（为空则用该源的首个分类）")
	page := fs.Int("page", 1, "页码")
	limit := fs.Int("limit", 10, "最多显示多少条书单")
	if err := fs.Parse(args); err != nil {
		return err
	}
	ctx := context.Background()

	if *sourceID == 0 {
		list, err := biz.Source.ListExploreSources(ctx)
		if err != nil {
			return err
		}
		if len(list) == 0 {
			fmt.Println("(没有支持发现的书源——书源需配置 exploreUrl)")
			return nil
		}
		fmt.Printf("%d 个书源支持发现（分类为展开时按需解析，这里顺带跑一遍便于排查）:\n", len(list))
		for _, s := range list {
			kinds, err := biz.Source.ExploreKinds(ctx, s.ID)
			if err != nil {
				fmt.Printf("  [%3d] %-24s 分类解析失败: %v\n", s.ID, truncate(s.Name, 24), err)
				continue
			}
			fmt.Printf("  [%3d] %-24s %d 个分类\n", s.ID, truncate(s.Name, 24), len(kinds))
			for i, k := range kinds {
				if i >= 8 {
					fmt.Printf("        … 另有 %d 个\n", len(kinds)-8)
					break
				}
				mark := ""
				if k.Paged {
					mark = " [可分页]"
				}
				fmt.Printf("        · %-20s %s%s\n", truncate(k.Title, 20), truncate(k.URL, 60), mark)
			}
		}
		return nil
	}

	start := time.Now()
	list, err := biz.Source.Explore(ctx, *sourceID, *url, *page)
	if err != nil {
		return err
	}
	fmt.Printf("发现书单 %d 条，耗时 %s\n", len(list), time.Since(start).Round(time.Millisecond))
	if *limit > 0 && len(list) > *limit {
		list = list[:*limit]
	}
	for _, r := range list {
		fmt.Printf("  %-32s 作者:%-14s 最新:%-16s\n      %s\n",
			truncate(r.Name, 32), truncate(r.Author, 14), truncate(r.LastChapter, 16), r.BookURL)
	}
	return nil
}

// cmdDownload 搜索并下载若干本书，导出为 TXT。
//
// 这是"书源下载"链路的端到端验证：搜索 → 入架 → 抓目录 → 抓正文 → 导出 TXT。
func cmdDownload(biz *bootstrap.App, args []string) error {
	fs := flag.NewFlagSet("download", flag.ContinueOnError)
	sourceID := fs.Int64("source", 0, "书源 ID")
	kw := fs.String("kw", "", "搜索关键词")
	bookURL := fs.String("url", "", "直接指定书籍 URL（跳过搜索）")
	name := fs.String("name", "", "书名（仅在 -url 时有效；详情规则取不到书名时用它兜底）")
	author := fs.String("author", "", "作者（仅在 -url 时有效）")
	pick := fs.Int("pick", 1, "下载搜索结果中的前几本")
	chapters := fs.Int("chapters", 5, "每本最多导出多少章（0 表示全部）")
	outDir := fs.String("out", filepath.Join(".", "downloads"), "TXT 输出目录")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *sourceID == 0 {
		return fmt.Errorf("需要 -source（先用 list 查看书源 ID）")
	}
	if *kw == "" && *bookURL == "" {
		return fmt.Errorf("需要 -kw 或 -url")
	}

	ctx := context.Background()

	// 确定待下载的书籍：可直接指定，也可由搜索结果取前几本。
	// 带上列表页已有的书名/作者，与 GUI 入架走同一条路径。
	// variable 是搜索阶段书源 @put 出来的变量，目录/正文的 @get 依赖它
	type target struct{ url, name, author, variable string }
	var targets []target
	if *bookURL != "" {
		targets = append(targets, target{*bookURL, *name, *author, ""})
	} else {
		found, err := biz.Source.Search(ctx, *sourceID, *kw, 1)
		if err != nil {
			return err
		}
		if len(found) == 0 {
			return fmt.Errorf("书源 %d 搜索 %q 无结果", *sourceID, *kw)
		}
		if *pick <= 0 || *pick > len(found) {
			*pick = len(found)
		}
		for _, r := range found[:*pick] {
			targets = append(targets, target{r.BookURL, r.Name, r.Author, r.Variable})
		}
	}

	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		return fmt.Errorf("创建输出目录失败: %w", err)
	}

	var failed int
	for i, t := range targets {
		fmt.Printf("\n---- 第 %d/%d 本: %s\n", i+1, len(targets), t.url)
		if err := downloadOne(ctx, biz, *sourceID, t.url, t.name, t.author, t.variable, *chapters, *outDir); err != nil {
			fmt.Printf("  >>> 失败: %v\n", err)
			failed++
		}
	}
	fmt.Printf("\n==== 完成: 成功 %d，失败 %d，输出目录 %s\n", len(targets)-failed, failed, *outDir)
	return nil
}

// downloadOne 下载单本书并导出 TXT。
func downloadOne(ctx context.Context, biz *bootstrap.App, sourceID int64, bookURL, name, author, variable string, maxChapters int, outDir string) error {
	brief, err := biz.Source.AddToShelf(ctx, sourceID, bookURL, name, author, variable, 0)
	if err != nil {
		return fmt.Errorf("入架失败: %w", err)
	}
	fmt.Printf("  入架: [%d] %s（作者 %s）\n", brief.ID, brief.Name, brief.Author)

	book, all, err := biz.Content.BookAndChapters(ctx, brief.ID)
	if err != nil {
		return fmt.Errorf("读取目录失败: %w", err)
	}
	if len(all) == 0 {
		return fmt.Errorf("该书没有章节")
	}
	fmt.Printf("  目录: %d 章\n", len(all))

	want := all
	if maxChapters > 0 && len(all) > maxChapters {
		want = all[:maxChapters]
	}
	fmt.Printf("  抓取正文: %d 章（可能因网络失败而少于此数）\n", len(want))

	dest := filepath.Join(outDir, sanitizeFileName(book.Name)+".txt")
	start := time.Now()
	if err := exportTXT(ctx, biz, book, want, dest); err != nil {
		return fmt.Errorf("导出失败: %w", err)
	}
	info, err := os.Stat(dest)
	size := int64(0)
	if err == nil {
		size = info.Size()
	}
	fmt.Printf("  已导出: %s（%d 字节，耗时 %s）\n", dest, size, time.Since(start).Round(time.Millisecond))
	return nil
}

// exportTXT 把指定章节导出为 TXT 文件。
func exportTXT(ctx context.Context, biz *bootstrap.App, book *domain.Book, chapters []*domain.BookChapter, dest string) error {
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer f.Close() //nolint:errcheck

	ex := exporter.NewTXTExporter()
	return ex.Export(ctx, f, book, chapters, biz.Content.FetchContent(ctx, book))
}

// fetchURL 下载 URL 内容。
func fetchURL(u string) ([]byte, error) {
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", downloadUA)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close() //nolint:errcheck
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// firstMessage 取最严重的一条问题文本用于展示。
//
// 必须按级别取：校验结果里既有「搜索成功，命中 3 条」（info）也有失败原因（error），
// 早先按顺序取第一条非空消息，导致 FAIL 行显示成「搜索成功…」，完全误导。
func firstMessage(in []dto.ValidationIssue) string {
	for _, want := range []string{"error", "warning"} {
		for _, i := range in {
			if strings.EqualFold(i.Level, want) && i.Message != "" {
				return i.Message
			}
		}
	}
	for _, i := range in {
		if i.Message != "" {
			return i.Message
		}
	}
	if len(in) > 0 {
		return in[0].Level + " " + in[0].Field
	}
	return "未知原因"
}

// truncate 截断字符串，超长时追加省略号。
func truncate(in string, limit int) string {
	runes := []rune(in)
	if len(runes) <= limit {
		return in
	}
	return string(runes[:limit]) + "…"
}

// sanitizeFileName 把书名转成安全的文件名。
//
// 与 internal/app 内的同名函数保持一致的规则：
// 去掉路径分隔符与 Windows 保留字符，避免写出到非法路径。
func sanitizeFileName(name string) string {
	replacer := strings.NewReplacer(
		"/", "_", "\\", "_", ":", "_", "*", "_",
		"?", "_", "\"", "_", "<", "_", ">", "_", "|", "_",
	)
	out := strings.TrimSpace(replacer.Replace(name))
	if out == "" {
		return "untitled"
	}
	if len([]rune(out)) > 80 {
		out = string([]rune(out)[:80])
	}
	return out
}
