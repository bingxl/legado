package bookparser

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"mime"
	"path"
	"regexp"
	"strings"
	"sync"

	"github.com/raitucarp/epub"
	"github.com/raitucarp/epub/pkg"
	"golang.org/x/net/html"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// EPUBParser 解析 EPUB 2/3 出版物，底层使用 github.com/raitucarp/epub。
//
// 章节按 spine 顺序组织（而非 manifest 顺序），保证与阅读顺序一致。
//
// 实例持有最近打开的一个 Reader 用于复用，因此不可在多处零值构造后混用；
// 由组合根统一创建并注入。
type EPUBParser struct {
	// mu 保护下面两个字段，同时也串行化对复用 Reader 的访问：
	// 底层 Reader 未声明并发安全，而读取章节远慢于加锁，串行化代价可以接受。
	mu         sync.Mutex
	cached     *epub.Reader
	cachedPath string
}

// NewEPUBParser 创建 EPUB 解析器。
func NewEPUBParser() *EPUBParser { return &EPUBParser{} }

var _ port.LocalBookParser = (*EPUBParser)(nil)

// Format 返回支持的格式。
func (p *EPUBParser) Format() domain.BookFormat { return domain.BookFormatEPUB }

// openLocked 在调用方已持有 mu 的前提下打开 EPUB，命中缓存时复用。
//
// 重复 OpenReader 会重新解压整个压缩包：实测 170MB 的 EPUB 每次约 1.4s，
// 若每读一章都付一次代价，翻页会明显卡顿。阅读时连续读取通常集中在同一本书，
// 因此只缓存最近打开的一个，既能消除翻页开销，
// 又避免多本大书的解压内容同时驻留内存。
func (p *EPUBParser) openLocked(filePath string) (*epub.Reader, error) {
	if p.cached != nil && p.cachedPath == filePath {
		return p.cached, nil
	}
	// 底层把压缩包内容全部载入内存且不持有文件句柄，被替换者由 GC 回收即可。
	book, err := epub.OpenReader(filePath)
	if err != nil {
		return nil, fmt.Errorf("%w: 无法打开 EPUB: %s", domain.ErrParseFailed, err.Error())
	}
	p.cached, p.cachedPath = &book, filePath
	return &book, nil
}

// Parse 解析 EPUB，抽取元数据、封面与章节结构。
func (p *EPUBParser) Parse(ctx context.Context, filePath string) (parsed *port.ParsedBook, err error) {
	// 兜底：EPUB 来自用户导入或网络下载，属于不可信输入，畸形文件可能让底层库 panic。
	// 若放任 panic 冒泡，整个桌面应用会随之退出，这不可接受，
	// 因此在解析边界统一降级为"解析失败"。
	defer func() {
		if r := recover(); r != nil {
			parsed, err = nil, panicAsError("解析 EPUB", r)
		}
	}()

	p.mu.Lock()
	defer p.mu.Unlock()

	book, err := p.openLocked(filePath)
	if err != nil {
		return nil, err
	}

	// 建立 href → 标题的映射，用于给 spine 条目命名。
	titles := hrefTitles(book)

	chapters := make([]*domain.BookChapter, 0)
	for _, res := range book.Spine() {
		// 只把内容文档（XHTML）视为章节，跳过封面、导航等非正文资源。
		if !isContentDocument(res.MIMEType) {
			continue
		}
		chapters = append(chapters, &domain.BookChapter{
			Index:    len(chapters),
			Title:    titles[normalizeHref(res.Href)], // 目录未收录时留空，稍后补全
			Resource: res.Href,
		})
	}
	if len(chapters) == 0 {
		return nil, fmt.Errorf("%w: EPUB 中没有可阅读的内容文档", domain.ErrParseFailed)
	}

	// 目录往往不收录标题页、目录页等 spine 条目，它们的标题留空。
	// 先从文档自身提取，仍取不到才退化为序号占位。
	fillTitlesFromDocument(book, chapters)
	for i, c := range chapters {
		if c.Title == "" {
			c.Title = fmt.Sprintf("第 %d 节", i+1)
		}
	}

	parsed = &port.ParsedBook{
		Chapters: chapters,
		Meta: port.BookMeta{
			Title:  firstOf(book.Title()),
			Author: strings.Join(book.Author(), "、"),
			Intro:  description(book),
		},
	}

	if href, data := coverImage(book); len(data) > 0 {
		parsed.Cover = io.NopCloser(bytes.NewReader(data))
		parsed.CoverExt = imageExt(href, data)
	}
	return parsed, nil
}

// description 安全读取书籍简介，失败时返回空串。
//
// 底层的 Reader.Description() 在部分 EPUB 上会 panic：
// 它取首个内容文档时未校验 ReadContentHTMLByHref 可能返回 nil，
// 随后把 nil 传给 FindNode 解引用（raitucarp/epub v0.5.1 缺陷）。
// 简介只是锦上添花的元信息，拿不到应留空而非让整本书解析失败，
// 因此这里对它单独兜底，与 Parse 的整体兜底区分开。
func description(book *epub.Reader) (desc string) {
	defer func() {
		if recover() != nil {
			desc = ""
		}
	}()
	return firstOf(book.Description())
}

// fillTitlesFromDocument 为缺少标题的章节从文档自身提取标题。
//
// 只对确实缺标题的章节读取文档，因此在大书上也不会带来明显开销。
// 取标题的优先级：<title> → 首个 h1/h2/h3。
func fillTitlesFromDocument(book *epub.Reader, chapters []*domain.BookChapter) {
	for _, ch := range chapters {
		if ch.Title != "" {
			continue
		}
		if title := documentTitle(book, ch.Resource); title != "" {
			ch.Title = title
		}
	}
}

// documentTitle 读取章节文档自身的标题；读取失败或没有标题时返回空串。
func documentTitle(book *epub.Reader, href string) (title string) {
	// 底层解析未校验内容文档缺失的情况，这里同样防御，避免整次解析中断。
	defer func() {
		if recover() != nil {
			title = ""
		}
	}()

	node := book.ReadContentHTMLByHref(href)
	if node == nil {
		return ""
	}
	if t := firstElementText(node, "title"); t != "" {
		return truncateTitle(t)
	}
	for _, tag := range []string{"h1", "h2", "h3"} {
		if t := firstElementText(node, tag); t != "" {
			return truncateTitle(t)
		}
	}
	return ""
}

// maxTitleLen 限制从文档提取的标题长度，避免把整段正文当标题。
const maxTitleLen = 60

// truncateTitle 截断标题，超长时追加省略号。
func truncateTitle(in string) string {
	runes := []rune(collapseSpace(in))
	if len(runes) <= maxTitleLen {
		return string(runes)
	}
	return string(runes[:maxTitleLen]) + "…"
}

// collapseSpace 把连续空白折叠为单个空格并去掉首尾空白。
func collapseSpace(in string) string {
	return strings.Join(strings.Fields(in), " ")
}

// firstElementText 返回文档中首个指定标签元素的文本内容。
func firstElementText(root *html.Node, tag string) string {
	var target *html.Node
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if target != nil || n == nil {
			return
		}
		if n.Type == html.ElementNode && n.Data == tag {
			target = n
			return
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
			if target != nil {
				return
			}
		}
	}
	walk(root)
	if target == nil {
		return ""
	}
	var sb strings.Builder
	for c := target.FirstChild; c != nil; c = c.NextSibling {
		if c.Type == html.TextNode {
			sb.WriteString(c.Data)
		}
	}
	return collapseSpace(sb.String())
}

// minCoverBytes 是判定封面有效的最小字节数。
//
// 实测有 EPUB 把损坏或占位的图片（仅 4 字节的 jpg）声明为封面，
// 照单全收会让书架上出现破图，因此低于阈值者视为无效，继续尝试下一个候选。
const minCoverBytes = 1024

// coverImage 定位封面资源并返回其原始字节；找不到有效封面时返回空。
//
// 这里刻意不使用上游的 Reader.CoverBytes()：它先把图像解码再重新编码为 PNG，
// 既损失原格式与画质，又在封面解码失败时因空指针直接 panic（raitucarp/epub v0.5.1 缺陷）。
// 改为自行定位资源后读取原始字节，可同时避开崩溃与重编码开销。
func coverImage(book *epub.Reader) (href string, data []byte) {
	for _, cand := range coverCandidates(book) {
		if raw := book.ReadImageBytesByHref(cand); len(raw) >= minCoverBytes {
			return cand, raw
		}
	}
	return "", nil
}

// coverCandidates 按 EPUB 规范优先级列出封面资源的候选 href，已去重。
//
// 顺序：metadata 的 <meta name="cover"> 声明 → manifest 的 cover-image 属性 → id 含 cover 的图片。
func coverCandidates(book *epub.Reader) []string {
	var out []string
	seen := make(map[string]bool)
	add := func(href string) {
		if href != "" && !seen[href] {
			seen[href] = true
			out = append(out, href)
		}
	}

	if meta, ok := book.Metadata()["meta"].(map[string]any); ok {
		for key, val := range meta {
			if !coverPattern.MatchString(key) {
				continue
			}
			id, isStr := val.(string)
			if !isStr {
				continue
			}
			if res := book.SelectResourceById(id); res != nil && isImageMIME(res.MIMEType) {
				add(res.Href)
			}
		}
	}

	// 属性声明的优先级高于仅靠 id 猜测，因此分两轮收集。
	var byID []string
	for _, res := range book.Resources() {
		if !isImageMIME(res.MIMEType) {
			continue
		}
		if res.Properties == pkg.CoverImageProperty {
			add(res.Href)
		}
		if coverPattern.MatchString(res.ID) {
			byID = append(byID, res.Href)
		}
	}
	for _, href := range byID {
		add(href)
	}
	return out
}

// coverPattern 用于匹配封面相关的键名与资源 ID。
var coverPattern = regexp.MustCompile(`(?i)cover`)

// isImageMIME 判断 MIME 是否为图片。
func isImageMIME(mimeType string) bool {
	return strings.HasPrefix(strings.ToLower(mimeType), "image/")
}

// Content 读取指定章节的正文。
//
// EPUB 正文里的图片是压缩包内的相对路径，浏览器无法直接访问。
// 这里把图片**内联为 data URI**，使章节内容自包含、无需额外路由。
// 已知限制：图片极多或极大时内存占用偏高；后续可改为按需解压 + 本地路由。
func (p *EPUBParser) Content(ctx context.Context, filePath string, chapter *domain.BookChapter) (content *port.ChapterContent, err error) {
	// 与 Parse 同理：对不可信输入做边界兜底，避免整应用退出。
	defer func() {
		if r := recover(); r != nil {
			content, err = nil, panicAsError("读取章节", r)
		}
	}()

	p.mu.Lock()
	defer p.mu.Unlock()

	book, err := p.openLocked(filePath)
	if err != nil {
		return nil, err
	}

	node := book.ReadContentHTMLByHref(chapter.Resource)
	if node == nil {
		return nil, fmt.Errorf("%w: 未找到章节内容 %q", domain.ErrParseFailed, chapter.Resource)
	}

	inlineImages(book, node, chapter.Resource)

	var buf bytes.Buffer
	if err := html.Render(&buf, node); err != nil {
		return nil, fmt.Errorf("%w: 渲染章节失败: %s", domain.ErrParseFailed, err.Error())
	}
	return &port.ChapterContent{
		Title: chapter.Title,
		HTML:  buf.String(),
	}, nil
}

// inlineImages 把节点内的 <img> 相对地址替换为 data URI。
func inlineImages(book *epub.Reader, node *html.Node, baseHref string) {
	base := path.Dir(baseHref)

	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.ElementNode && n.Data == "img" {
			for i, attr := range n.Attr {
				if attr.Key != "src" {
					continue
				}
				src := attr.Val
				if strings.HasPrefix(src, "data:") || strings.HasPrefix(src, "http") {
					continue
				}
				resolved := src
				if base != "" && base != "." && !strings.HasPrefix(src, "/") {
					resolved = path.Join(base, src)
				}
				data := book.ReadImageBytesByHref(resolved)
				if len(data) == 0 {
					continue
				}
				n.Attr[i].Val = dataURI(data, resolved)
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(node)
}

// hrefTitles 从目录（NAV/NCX）中提取 href → 标题 的映射，递归展开层级。
func hrefTitles(book *epub.Reader) map[string]string {
	out := make(map[string]string)
	toc, err := book.TableOfContents()
	if err != nil {
		return out
	}
	var walk func(items []epub.TOC)
	walk = func(items []epub.TOC) {
		for _, it := range items {
			if it.Href != "" && it.Title != "" {
				key := normalizeHref(it.Href)
				if _, ok := out[key]; !ok {
					out[key] = strings.TrimSpace(it.Title)
				}
			}
			walk(it.Items)
		}
	}
	walk(toc.Items)
	return out
}

// normalizeHref 规整 href：去掉 fragment 与开头的 ./。
func normalizeHref(href string) string {
	if i := strings.IndexAny(href, "#?"); i >= 0 {
		href = href[:i]
	}
	return strings.TrimPrefix(href, "./")
}

// isContentDocument 判断 MIME 是否为内容文档。
func isContentDocument(mimeType string) bool {
	m := strings.ToLower(mimeType)
	return strings.Contains(m, "xhtml") || strings.Contains(m, "html") || m == "text/xml"
}

// dataURI 把图片字节转为 data URI。
func dataURI(data []byte, href string) string {
	ct := mime.TypeByExtension(strings.ToLower(path.Ext(href)))
	if ct == "" {
		ct = "image/jpeg"
	}
	return fmt.Sprintf("data:%s;base64,%s", ct, base64Encode(data))
}

// base64Encode 做标准 Base64 编码。
func base64Encode(data []byte) string { return base64.StdEncoding.EncodeToString(data) }

// firstOf 返回切片首元素，空切片返回空串。
func firstOf(in []string) string {
	if len(in) == 0 {
		return ""
	}
	return in[0]
}

// imageExt 推断图片扩展名：优先信任文件自身的扩展名，缺失时按魔数兜底。
func imageExt(href string, data []byte) string {
	if ext := strings.ToLower(path.Ext(href)); ext != "" && len(ext) <= 5 {
		return ext
	}
	switch {
	case len(data) > 8 && bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")):
		return ".png"
	case len(data) > 3 && bytes.HasPrefix(data, []byte("GIF")):
		return ".gif"
	case len(data) > 2 && data[0] == 0xFF && data[1] == 0xD8:
		return ".jpg"
	case len(data) > 12 && bytes.HasPrefix(data[4:], []byte("ftyp")):
		return ".webp"
	case len(data) > 1 && data[0] == 'B' && data[1] == 'M':
		return ".bmp"
	default:
		return ".jpg"
	}
}

// panicAsError 把解析过程中捕获的 panic 转为领域错误。
//
// 见 Parse 中关于不可信输入的说明：这是解析边界的兜底，不是掩盖内部缺陷。
func panicAsError(phase string, r any) error {
	return fmt.Errorf("%w: %s 时解析库异常: %v", domain.ErrParseFailed, phase, r)
}
