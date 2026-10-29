package bookparser

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ComicParser 解析漫画/图片集，支持：
//   - 压缩格式：.cbz / .zip / .cbr / .rar / .7z / .cb7（纯 Go 解压，无需 cgo）
//   - 普通目录：目录内的图片文件
//
// 组织规则：若包内顶层存在多个子目录，则**每个子目录视为一话**；
// 否则整本视为一话。这样既适配"一册一话"，也适配"合集多话"。
//
// 图片访问策略：内容读取时把图片落到缓存目录，再以 /local/ 前缀的 URL
// 提供给前端。这样 WebView 无需直接访问用户文件系统，
// 也避免了把整本漫画以 base64 塞进内存。
type ComicParser struct {
	// CacheDir 是图片缓存根目录（磁盘）。
	CacheDir string
	// URLPrefix 是前端访问缓存图片的前缀，如 "/local/comic"。
	URLPrefix string
}

// NewComicParser 创建漫画解析器。
func NewComicParser(cacheDir, urlPrefix string) *ComicParser {
	if urlPrefix == "" {
		urlPrefix = "/local/comic"
	}
	return &ComicParser{CacheDir: cacheDir, URLPrefix: urlPrefix}
}

var _ port.LocalBookParser = (*ComicParser)(nil)

// 支持的图片扩展名。
var comicImageExts = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true, ".gif": true,
	".webp": true, ".bmp": true, ".avif": true, ".jxl": true,
}

// Format 返回支持的格式。
func (p *ComicParser) Format() domain.BookFormat { return domain.BookFormatComic }

// Parse 解析漫画文件（压缩包）或目录。
func (p *ComicParser) Parse(ctx context.Context, sourcePath string) (*port.ParsedBook, error) {
	info, err := os.Stat(sourcePath)
	if err != nil {
		return nil, fmt.Errorf("访问路径失败: %w", err)
	}

	var groups map[string][]string // 话名 → 图片内部路径
	var isArchive bool

	if info.IsDir() {
		groups, err = p.scanDir(sourcePath)
	} else {
		groups, err = p.scanArchive(sourcePath)
		isArchive = true
	}
	if err != nil {
		return nil, err
	}
	if len(groups) == 0 {
		return nil, fmt.Errorf("%w: 未找到任何图片", domain.ErrParseFailed)
	}

	parsed := &port.ParsedBook{
		Meta: port.BookMeta{
			Title: strings.TrimSuffix(filepath.Base(sourcePath), filepath.Ext(sourcePath)),
		},
	}

	// 单组（"*"）时视为一话；多组时按自然序排列，每组一话。
	if len(groups) == 1 {
		if imgs, ok := groups["*"]; ok {
			parsed.Chapters = []*domain.BookChapter{{
				Index: 0, Title: "第 1 话", Resource: "*",
				URL: fmt.Sprintf("%d", len(imgs)),
			}}
			return parsed, nil
		}
	}

	names := make([]string, 0, len(groups))
	for name := range groups {
		if name == "*" {
			continue
		}
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool { return naturalLess(names[i], names[j]) })

	parsed.Chapters = make([]*domain.BookChapter, 0, len(names))
	for i, name := range names {
		sort.Slice(groups[name], func(a, b int) bool { return naturalLess(groups[name][a], groups[name][b]) })
		parsed.Chapters = append(parsed.Chapters, &domain.BookChapter{
			Index:    i,
			Title:    name,
			Resource: name,
			URL:      fmt.Sprintf("%d", len(groups[name])),
		})
	}
	_ = isArchive
	return parsed, nil
}

// Content 取出某一话的全部图片，返回可访问 URL 列表。
func (p *ComicParser) Content(ctx context.Context, sourcePath string, chapter *domain.BookChapter) (*port.ChapterContent, error) {
	info, err := os.Stat(sourcePath)
	if err != nil {
		return nil, fmt.Errorf("访问路径失败: %w", err)
	}

	// 用「源文件路径 + 话名」生成稳定的缓存目录，避免重复解压。
	key := cacheKey(sourcePath)
	target := filepath.Join(p.CacheDir, key, sanitizeDir(chapter.Resource))

	var urls []string
	if info.IsDir() {
		urls, err = p.materializeDir(sourcePath, chapter.Resource, target)
	} else {
		urls, err = p.materializeArchive(sourcePath, chapter.Resource, target)
	}
	if err != nil {
		return nil, err
	}
	if len(urls) == 0 {
		return nil, fmt.Errorf("%w: 该话没有可用图片", domain.ErrParseFailed)
	}

	return &port.ChapterContent{
		Title:  chapter.Title,
		Images: urls,
	}, nil
}

// scanArchive 扫描压缩包，按顶层目录分组图片。
//
// 支持 zip / rar / 7z（由 comic_archive.go 统一处理），
// 扩展名与真实格式不一致时按文件头判断。
func (p *ComicParser) scanArchive(archivePath string) (map[string][]string, error) {
	ar, err := openComicArchive(archivePath)
	if err != nil {
		return nil, err
	}
	defer ar.close() //nolint:errcheck

	groups := make(map[string][]string)
	for _, name := range ar.images() {
		group := "*"
		if idx := strings.Index(name, "/"); idx > 0 {
			group = name[:idx]
		}
		groups[group] = append(groups[group], name)
	}
	for k := range groups {
		sort.Slice(groups[k], func(i, j int) bool { return naturalLess(groups[k][i], groups[k][j]) })
	}
	return groups, nil
}

// scanDir 扫描目录，按子目录分组图片。
func (p *ComicParser) scanDir(root string) (map[string][]string, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, fmt.Errorf("读取目录失败: %w", err)
	}
	groups := make(map[string][]string)

	var collect func(dir, group string)
	collect = func(dir, group string) {
		items, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range items {
			if e.IsDir() {
				collect(filepath.Join(dir, e.Name()), group)
				continue
			}
			if !comicImageExts[strings.ToLower(filepath.Ext(e.Name()))] {
				continue
			}
			rel, _ := filepath.Rel(root, filepath.Join(dir, e.Name()))
			groups[group] = append(groups[group], filepath.ToSlash(rel))
		}
	}

	// 顶层子目录各自成话；顶层散落的图片归为单独一话。
	hasSubDir := false
	for _, e := range entries {
		if e.IsDir() {
			hasSubDir = true
			collect(filepath.Join(root, e.Name()), e.Name())
		}
	}
	if !hasSubDir {
		collect(root, "*")
	} else {
		// 顶层还有散图时，也把它们收成一话。
		var loose []string
		for _, e := range entries {
			if !e.IsDir() && comicImageExts[strings.ToLower(filepath.Ext(e.Name()))] {
				loose = append(loose, e.Name())
			}
		}
		if len(loose) > 0 {
			groups["*"] = loose
		}
	}
	return groups, nil
}

// materializeArchive 解压指定话的图片到缓存目录。
func (p *ComicParser) materializeArchive(src, group, target string) ([]string, error) {
	ar, err := openComicArchive(src)
	if err != nil {
		return nil, err
	}
	defer ar.close() //nolint:errcheck

	if err := os.MkdirAll(target, 0o755); err != nil {
		return nil, fmt.Errorf("创建缓存目录失败: %w", err)
	}

	// 先把属于本话的条目名挑出来，再交给归档层批量解压。
	want := make(map[string]bool)
	for _, name := range ar.images() {
		if inGroup(name, group) {
			want[name] = true
		}
	}
	if len(want) == 0 {
		return nil, nil
	}

	urls := make([]string, 0, len(want))
	base := map[string]string{} // 条目名 → 落盘文件名
	for name := range want {
		file := sanitizeDir(filepath.Base(name))
		base[name] = file
		urls = append(urls, p.imageURL(target, file))
	}
	if _, err := ar.extract(want, func(name string) string {
		return filepath.Join(target, base[name])
	}); err != nil {
		return nil, err
	}
	sort.Slice(urls, func(i, j int) bool { return naturalLess(urls[i], urls[j]) })
	return urls, nil
}

// materializeDir 把目录中的图片复制到缓存目录，使访问路径统一。
func (p *ComicParser) materializeDir(src, group, target string) ([]string, error) {
	var relPaths []string
	if group == "*" {
		entries, err := os.ReadDir(src)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			if !e.IsDir() && comicImageExts[strings.ToLower(filepath.Ext(e.Name()))] {
				relPaths = append(relPaths, e.Name())
			}
		}
	} else {
		// 递归闭包必须先声明再赋值，否则无法在内部引用自身。
		var walk func(dir string)
		walk = func(dir string) {
			items, _ := os.ReadDir(dir)
			for _, e := range items {
				if e.IsDir() {
					walk(filepath.Join(dir, e.Name()))
					continue
				}
				if comicImageExts[strings.ToLower(filepath.Ext(e.Name()))] {
					rel, _ := filepath.Rel(src, filepath.Join(dir, e.Name()))
					relPaths = append(relPaths, filepath.ToSlash(rel))
				}
			}
		}
		walk(filepath.Join(src, group))
	}
	sort.Slice(relPaths, func(i, j int) bool { return naturalLess(relPaths[i], relPaths[j]) })
	if err := os.MkdirAll(target, 0o755); err != nil {
		return nil, fmt.Errorf("创建缓存目录失败: %w", err)
	}

	urls := make([]string, 0, len(relPaths))
	for _, rel := range relPaths {
		dest := filepath.Join(target, sanitizeDir(filepath.Base(rel)))
		if err := copyFile(filepath.Join(src, filepath.FromSlash(rel)), dest); err != nil {
			continue
		}
		urls = append(urls, p.imageURL(target, filepath.Base(dest)))
	}
	return urls, nil
}

// imageURL 生成前端可访问的 URL。
func (p *ComicParser) imageURL(dir, name string) string {
	rel, err := filepath.Rel(p.CacheDir, filepath.Join(dir, name))
	if err != nil {
		return ""
	}
	return strings.TrimSuffix(p.URLPrefix, "/") + "/" + filepath.ToSlash(rel)
}

// inGroup 判断压缩包内路径是否属于指定话。
func inGroup(name, group string) bool {
	if group == "*" {
		return !strings.Contains(name, "/")
	}
	return strings.HasPrefix(name, group+"/")
}

// copyFile 复制文件。
func copyFile(src, dest string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

// cacheKey 由源路径生成稳定的缓存目录名。
func cacheKey(path string) string {
	abs, _ := filepath.Abs(path)
	h := uint32(2166136261)
	for _, c := range abs {
		h ^= uint32(c)
		h *= 16777619
	}
	base := strings.TrimSuffix(filepath.Base(abs), filepath.Ext(abs))
	return fmt.Sprintf("%s-%08x", sanitizeDir(base), h)
}

// sanitizeDir 清理目录名中的非法字符。
//
// 注意必须覆盖 Windows 的保留字符（* ? " < > | 等），
// 否则在 Windows 上创建目录会直接失败。
func sanitizeDir(name string) string {
	r := strings.NewReplacer(
		"/", "_", "\\", "_", "..", "_", ":", "_",
		"*", "_", "?", "_", `"`, "_", "<", "_", ">", "_", "|", "_",
	)
	out := r.Replace(strings.TrimSpace(name))
	if out == "" {
		return "_"
	}
	return out
}

// naturalLess 实现自然排序：把数字串按数值比较，
// 使 "第2话" 排在 "第10话" 之前，而非字典序的 "10" < "2"。
func naturalLess(a, b string) bool {
	ra, rb := []rune(a), []rune(b)
	for i, j := 0, 0; i < len(ra) && j < len(rb); {
		if isDigitRune(ra[i]) && isDigitRune(rb[j]) {
			ni, nii := readNumber(ra, i)
			nj, njj := readNumber(rb, j)
			if ni != nj {
				return ni < nj
			}
			// 数值相同则比较位数（前导零），再继续。
			if nii != njj {
				return nii < njj
			}
			i, j = i+nii, j+njj
			continue
		}
		if ra[i] != rb[j] {
			return ra[i] < rb[j]
		}
		i++
		j++
	}
	return len(ra) < len(rb)
}

// isDigitRune 判断是否为数字字符。
func isDigitRune(r rune) bool { return r >= '0' && r <= '9' }

// readNumber 从位置 i 读取连续数字，返回数值与长度。
func readNumber(s []rune, i int) (int, int) {
	n, start := 0, i
	for i < len(s) && isDigitRune(s[i]) {
		n = n*10 + int(s[i]-'0')
		i++
	}
	return n, i - start
}
