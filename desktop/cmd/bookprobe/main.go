// Command bookprobe 对本地书籍文件做端到端解析探测，用于验证解析器的正确性。
//
// 它是开发工具而非产品功能：绕过 UI 与数据库，直接调用 internal/adapter/bookparser，
// 输出元数据、目录结构与指定章节的正文，便于快速定位解析缺陷。
//
// 用法：
//
//	bookprobe <文件路径>              解析并列出目录
//	bookprobe -chapter 3 <文件路径>   额外读取第 3 章（从 0 开始）的正文
//
// 退出码：0 成功，1 解析失败或使用方式错误。
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"

	"golang.org/x/net/html"

	"github.com/legado/desktop/internal/adapter/bookparser"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// listLimit 限制目录预览的章节数，避免长篇书籍刷屏。
const listLimit = 12

// previewLimit 限制正文纯文本预览的字数。
const previewLimit = 300

func main() {
	// 支持逗号分隔的多个序号：阅读是连续行为，
	// 只有在同一进程内连读才能真实反映"翻页"时重复打开压缩包的开销。
	chapter := flag.String("chapter", "", "要读取正文的章节序号，从 0 开始，逗号分隔可连读多章；留空表示不读取")
	flag.Parse()

	args := flag.Args()
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "用法: bookprobe [-chapter N] <文件路径>")
		os.Exit(1)
	}
	path := args[0]

	indices, err := parseIndices(*chapter)
	if err != nil {
		fmt.Fprintf(os.Stderr, "错误: %v\n", err)
		os.Exit(1)
	}

	if err := run(path, indices); err != nil {
		fmt.Fprintf(os.Stderr, "错误: %v\n", err)
		os.Exit(1)
	}
}

// parseIndices 解析逗号分隔的章节序号；空串表示不读取正文。
func parseIndices(in string) ([]int, error) {
	if strings.TrimSpace(in) == "" {
		return nil, nil
	}
	var out []int
	for _, part := range strings.Split(in, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		n, err := strconv.Atoi(part)
		if err != nil {
			return nil, fmt.Errorf("章节序号 %q 不是整数", part)
		}
		out = append(out, n)
	}
	return out, nil
}

// run 执行一次探测并把结果打印到标准输出。
func run(filePath string, indices []int) error {
	format := domain.ParseBookFormat(strings.ToLower(filepath.Ext(filePath)))
	if format == domain.BookFormatUnknown {
		return fmt.Errorf("无法从扩展名识别格式: %s", filepath.Ext(filePath))
	}

	parser, err := newRegistry().Resolve(format)
	if err != nil {
		return err
	}

	start := time.Now()
	parsed, err := parser.Parse(context.Background(), filePath)
	if err != nil {
		return err
	}
	parseCost := time.Since(start)

	printMeta(filePath, format, parsed, parseCost)
	printChapters(parsed.Chapters)

	for _, idx := range indices {
		if idx >= len(parsed.Chapters) {
			return fmt.Errorf("章节序号 %d 超出范围（共 %d 章）", idx, len(parsed.Chapters))
		}
		if err := printContent(parser, filePath, parsed.Chapters[idx]); err != nil {
			return err
		}
	}
	return nil
}

// newRegistry 装配全部解析器，与生产环境保持一致的组合方式。
func newRegistry() *bookparser.Registry {
	reg := bookparser.NewRegistry()
	reg.Register(bookparser.NewTXTParser())
	reg.Register(bookparser.NewEPUBParser())
	reg.Register(bookparser.NewPDFParser())
	// 漫画解析器会把压缩包解压到缓存目录；探测时用临时目录以免污染应用数据。
	reg.Register(bookparser.NewComicParser(filepath.Join(os.TempDir(), "bookprobe-comic"), "/tmp/comic"))
	return reg
}

// printMeta 打印文件与元数据信息。
func printMeta(filePath string, format domain.BookFormat, parsed *port.ParsedBook, cost time.Duration) {
	info, _ := os.Stat(filePath)
	size := int64(0)
	if info != nil {
		size = info.Size()
	}

	fmt.Printf("文件    : %s\n", filePath)
	fmt.Printf("格式    : %s (%.1f MB)\n", format.String(), float64(size)/1024/1024)
	fmt.Printf("标题    : %s\n", fallback(parsed.Meta.Title, "(无)"))
	fmt.Printf("作者    : %s\n", fallback(parsed.Meta.Author, "(无)"))
	fmt.Printf("简介    : %s\n", oneLine(fallback(parsed.Meta.Intro, "(无)")))
	fmt.Printf("封面    : %s\n", coverDesc(parsed))
	fmt.Printf("章节数  : %d\n", len(parsed.Chapters))
	fmt.Printf("解析耗时: %s\n", cost.Round(time.Millisecond))
	fmt.Println()
}

// printChapters 打印目录预览。
func printChapters(chapters []*domain.BookChapter) {
	if len(chapters) == 0 {
		fmt.Println("目录    : (空)")
		return
	}
	fmt.Println("目录预览:")
	for i, c := range chapters {
		if i >= listLimit {
			fmt.Printf("  ... 其余 %d 章省略\n", len(chapters)-listLimit)
			break
		}
		fmt.Printf("  [%3d] %s\n", c.Index, truncate(c.Title, 48))
	}
	fmt.Println()
}

// printContent 读取并打印指定章节的正文统计与预览。
func printContent(parser port.LocalBookParser, filePath string, chapter *domain.BookChapter) error {
	start := time.Now()
	content, err := parser.Content(context.Background(), filePath, chapter)
	if err != nil {
		return err
	}
	cost := time.Since(start)

	text := stripHTML(content.HTML)
	fmt.Printf("章节 [%d] %s\n", chapter.Index, chapter.Title)
	fmt.Printf("  定位    : %s\n", fallback(chapter.Resource, "(无)"))
	fmt.Printf("  HTML    : %d 字符\n", len(content.HTML))
	fmt.Printf("  纯文本  : %d 字符\n", len(text))
	fmt.Printf("  图片    : %d\n", len(content.Images))
	fmt.Printf("  读取耗时: %s\n", cost.Round(time.Millisecond))
	fmt.Printf("  预览    : %s\n", truncate(text, previewLimit))
	return nil
}

// coverDesc 描述封面情况，含完整字节数（便于发现拿到空/损坏资源的缺陷）。
func coverDesc(parsed *port.ParsedBook) string {
	if parsed.Cover == nil {
		return "(无)"
	}
	defer parsed.Cover.Close() //nolint:errcheck
	// 统计完整字节数而非只探前 64 字节，否则无法分辨"真封面"与"读到残片"。
	n, _ := io.Copy(io.Discard, parsed.Cover)
	return fmt.Sprintf("有 (扩展名 %s, %d 字节)", fallback(parsed.CoverExt, "?"), n)
}

// stripHTML 把 HTML 转为纯文本，用于字数统计与预览。
func stripHTML(in string) string {
	node, err := html.Parse(strings.NewReader(in))
	if err != nil {
		return in
	}
	var sb strings.Builder
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.TextNode {
			sb.WriteString(n.Data)
			sb.WriteByte('\n')
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(node)
	return collapseSpace(sb.String())
}

// collapseSpace 把连续空白折叠为单个空格，并去掉首尾空白。
func collapseSpace(in string) string {
	return strings.Join(strings.FieldsFunc(in, unicode.IsSpace), " ")
}

// oneLine 把多行文本压成一行。
func oneLine(in string) string {
	return truncate(collapseSpace(in), 80)
}

// truncate 截断字符串，超长时追加省略号。
func truncate(in string, limit int) string {
	runes := []rune(in)
	if len(runes) <= limit {
		return in
	}
	return string(runes[:limit]) + "…"
}

// fallback 在 s 为空时返回 alt。
func fallback(s, alt string) string {
	if strings.TrimSpace(s) == "" {
		return alt
	}
	return s
}
