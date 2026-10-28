package download

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/net"
	"github.com/legado/legado-go/pkg/util"
	"github.com/legado/legado-go/pkg/webbook"
)

// Options 下载参数
type Options struct {
	OutDir   string                              // 输出目录
	Format   string                              // txt | md | images
	Workers  int                                 // 并发数
	Max      int                                 // 最多下载章节数，0 表示全部
	Start    int                                 // 起始章节下标
	Progress func(done, total int, title string) // 进度回调
}

// Result 下载结果
type Result struct {
	Title    string
	Author   string
	Path     string
	Chapters int
	Failed   []int
	Images   int
}

// DownloadBook 下载整本书（文本或漫画）
func DownloadBook(src *model.BookSource, book *model.Book, opt Options) (*Result, error) {
	if opt.OutDir == "" {
		opt.OutDir = "."
	}
	if opt.Workers <= 0 {
		opt.Workers = 4
	}
	if opt.Format == "" {
		if src.GetBookType() == model.BookTypeImage {
			opt.Format = "images"
		} else {
			opt.Format = "txt"
		}
	}
	// 1. 补全详情（拿到 tocUrl）
	if book.TocUrl == "" {
		if err := webbook.GetBookInfo(src, book); err != nil {
			return nil, fmt.Errorf("获取书籍详情失败: %w", err)
		}
	}
	// 2. 目录
	chapters, err := webbook.GetChapterList(src, book, false)
	if err != nil {
		return nil, fmt.Errorf("获取目录失败: %w", err)
	}
	if len(chapters) == 0 {
		return nil, fmt.Errorf("目录为空")
	}
	from := max(opt.Start, 0)
	if from >= len(chapters) {
		return nil, fmt.Errorf("起始下标 %d 超出目录范围(%d)", from, len(chapters))
	}
	to := len(chapters)
	if opt.Max > 0 && from+opt.Max < to {
		to = from + opt.Max
	}
	selected := chapters[from:to]

	res := &Result{Title: book.Name, Author: book.Author, Chapters: len(selected)}

	// 3. 并发抓取
	contents := make([]string, len(selected))
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, opt.Workers)
	done := 0
	for i, ch := range selected {
		// Go 1.22 起循环变量每轮独立，闭包直接捕获，不必再写 i, ch := i, ch
		wg.Go(func() {
			sem <- struct{}{}
			defer func() { <-sem }()
			next := ""
			if i+1 < len(selected) {
				next = selected[i+1].Url
			}
			c, err := webbook.GetContent(src, book, ch, next)
			mu.Lock()
			if err != nil || strings.TrimSpace(c) == "" {
				res.Failed = append(res.Failed, from+i)
			} else {
				contents[i] = c
			}
			done++
			d := done
			mu.Unlock()
			if opt.Progress != nil {
				opt.Progress(d, len(selected), ch.Title)
			}
		})
	}
	wg.Wait()

	if opt.Format == "images" {
		return saveImages(src, book, selected, contents, opt, res)
	}
	return saveText(book, selected, contents, opt, res)
}

func saveText(book *model.Book, chapters []*model.BookChapter, contents []string, opt Options, res *Result) (*Result, error) {
	var sb strings.Builder
	if opt.Format == "md" {
		sb.WriteString("# " + book.Name + "\n\n")
		if book.Author != "" {
			sb.WriteString("> 作者: " + book.Author + "\n\n")
		}
	} else {
		sb.WriteString(book.Name + "\n")
		if book.Author != "" {
			sb.WriteString("作者: " + book.Author + "\n\n")
		}
	}
	for i, ch := range chapters {
		if opt.Format == "md" {
			sb.WriteString("\n## " + ch.Title + "\n\n")
		} else {
			sb.WriteString("\n\n" + ch.Title + "\n\n")
		}
		sb.WriteString(contents[i])
	}
	ext := ".txt"
	if opt.Format == "md" {
		ext = ".md"
	}
	_ = os.MkdirAll(opt.OutDir, 0o755)
	path := filepath.Join(opt.OutDir, safeFileName(book.Name)+ext)
	if err := os.WriteFile(path, []byte(sb.String()), 0o644); err != nil {
		return nil, err
	}
	res.Path = path
	return res, nil
}

// saveImages 漫画模式：正文规则产出的是图片地址（每行一个）
func saveImages(src *model.BookSource, book *model.Book, chapters []*model.BookChapter, contents []string, opt Options, res *Result) (*Result, error) {
	base := filepath.Join(opt.OutDir, safeFileName(book.Name))
	_ = os.MkdirAll(base, 0o755)
	headers := src.GetHeaderMap(true)
	saveCookie := src.EnabledCookieJarOn()
	count := 0
	for i, ch := range chapters {
		dir := filepath.Join(base, fmt.Sprintf("%04d_%s", i, safeFileName(ch.Title)))
		_ = os.MkdirAll(dir, 0o755)
		idx := 0
		for _, u := range ExtractImages(contents[i]) {
			idx++
			data, err := net.Default().GetBytes(u, headers, saveCookie)
			if err != nil || len(data) == 0 {
				continue
			}
			name := fmt.Sprintf("%03d%s", idx, imageExt(u))
			if err := os.WriteFile(filepath.Join(dir, name), data, 0o644); err != nil {
				continue
			}
			count++
		}
	}
	res.Path = base
	res.Images = count
	slices.Sort(res.Failed)
	return res, nil
}

var imgSrcRe = regexp.MustCompile(`(?is)<img[^>]*\s(?:data-src|data-original|src)\s*=\s*["']([^"']+)["']`)

// ExtractImages 从章节正文中抽取图片地址（按出现顺序去重）
// 正文既可能是每行一个 <img src="...">，也可能是每行一个裸地址，两种都兼容。
func ExtractImages(content string) []string {
	var out []string
	seen := map[string]bool{}
	add := func(u string) {
		// 去掉可能被拼在地址后的 URL 选项 ,{...}
		if i := strings.Index(u, ",{"); i > 0 {
			u = u[:i]
		}
		u = strings.TrimSpace(u)
		if u == "" || !util.IsAbsUrl(u) || seen[u] {
			return
		}
		seen[u] = true
		out = append(out, u)
	}
	for line := range strings.SplitSeq(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.Contains(strings.ToLower(line), "<img") {
			for _, m := range imgSrcRe.FindAllStringSubmatch(line, -1) {
				if len(m) > 1 {
					add(m[1])
				}
			}
			continue
		}
		add(line)
	}
	return out
}

func imageExt(u string) string {
	s := strings.ToLower(util.GetSuffix(u))
	switch s {
	case "jpg", "jpeg", "png", "gif", "webp", "bmp":
		return "." + s
	}
	return ".jpg"
}

func safeFileName(name string) string {
	r := strings.NewReplacer(
		`\`, "_", "/", "_", ":", "_", "*", "_",
		"?", "_", `"`, "_", "<", "_", ">", "_", "|", "_",
	)
	n := r.Replace(strings.TrimSpace(name))
	if n == "" {
		n = "untitled"
	}
	if len([]rune(n)) > 80 {
		n = string([]rune(n)[:80])
	}
	return n
}

// String 结果摘要
func (r *Result) String() string {
	s := fmt.Sprintf("《%s》 章节 %d 已保存至 %s", r.Title, r.Chapters, r.Path)
	if r.Images > 0 {
		s += fmt.Sprintf("（图片 %d 张）", r.Images)
	}
	if len(r.Failed) > 0 {
		parts := make([]string, 0, len(r.Failed))
		for _, i := range r.Failed {
			parts = append(parts, strconv.Itoa(i))
		}
		s += "\n失败章节下标: " + strings.Join(parts, ",")
	}
	return s
}
