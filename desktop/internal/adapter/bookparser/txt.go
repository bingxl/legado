package bookparser

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	regexp2 "github.com/dlclark/regexp2/v2"
	legadoutil "github.com/legado/legado-go/pkg/util"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// TXTParser 解析纯文本文件。
//
// 两个关键问题：
//  1. 编码：中文 TXT 常见 GBK/Big5，需先检测再转 UTF-8（复用 legado-go 的实现）；
//  2. 目录：靠正则从正文里"认"出章节标题行。
//
// 目录规则默认使用 legado 风格的内置规则。这些规则包含**环视**语法
// （如 `(?!`、`(?<=`），而 Go 标准库的 RE2 不支持环视，
// 因此这里必须用 regexp2（回溯引擎）而非 regexp。
// 详见 docs：这是从 Java 正则迁移时最容易踩的坑。
type TXTParser struct {
	// Rules 是目录行匹配规则，按顺序尝试，命中即视为章节标题。
	Rules []string
	// MaxChapterChars 是找不到任何目录时按字数强制分章的阈值。
	MaxChapterChars int
}

// NewTXTParser 创建 TXT 解析器并载入默认目录规则。
func NewTXTParser() *TXTParser {
	return &TXTParser{
		Rules:           DefaultTxtTocRules(),
		MaxChapterChars: 5000,
	}
}

var _ port.LocalBookParser = (*TXTParser)(nil)

// Format 返回支持的格式。
func (p *TXTParser) Format() domain.BookFormat { return domain.BookFormatTXT }

// DefaultTxtTocRules 返回内置的 TXT 目录规则。
//
// 直接沿用 legado `assets/defaultData/txtTocRule.json` 中 enable=true 的 11 条规则
// （原始正则，一字未改）。它们是**Java 正则**，依赖环视与惰性量词：
//
//	(?<=[　\s])     行首前一个字符是空白（配合全文多行模式定位行首）
//	(?!完|结)       排除「第一章 完」「正文结束」这类误命中
//	[\d〇零一二…]   阿拉伯数字与中文数字混排的章节序号
//
// RE2 不支持环视，必须交给 regexp2（回溯引擎）编译，否则这些规则会整条失效，
// 表现为「TXT 一本都识别不出目录，全按 5000 字强行切章」。
func DefaultTxtTocRules() []string {
	return []string{
		// 目录(去空白)：允许标题前有全角/半角空格，且不要求行首对齐
		`(?<=[　\s])(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和]))).{0,30}$`,
		// 目录：标准行首写法
		`^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|篇(?!张))).{0,30}$`,
		// 数字 分隔符 标题名称
		`^[ 　\t]{0,4}\d{1,5}[:：,.， 、_—\-].{1,30}$`,
		// 大写数字 分隔符 标题名称
		`^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章?)[ 、_—\-].{1,30}$`,
		// 正文 标题/序号
		`^[ 　\t]{0,4}正文[ 　]{1,4}.{0,20}$`,
		// Chapter/Section/Part/Episode 序号 标题
		`^[ 　\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][oO][.、]|[Ee]pisode|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)\s{0,4}\d{1,4}.{0,30}$`,
		// 特殊符号 序号 标题：【第一章 xxx】
		`(?<=[\s　])[【〔〖「『〈［\[](?:第|[Cc]hapter)[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,10}[章节].{0,20}$`,
		// 特殊符号 标题(单个)：☆ 标题
		`(?<=[\s　]{0,4})(?:[☆★✦✧].{1,30}|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$`,
		// 章/卷 序号 标题
		`^[ \t　]{0,4}(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[卷章][\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8})[ 　]{0,4}.{0,30}$`,
		// 书名 括号 序号：书名（一）
		`^[一-龥]{1,20}[ 　\t]{0,4}[(（][\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[)）][ 　\t]{0,4}$`,
		// 书名 序号：书名 一
		`^[一-龥]{1,20}[ 　\t]{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[ 　\t]{0,4}$`,
		// 字数分割 分节阅读
		`(?<=[ 　\t]{0,4})(?:.{0,15}分[页节章段]阅读[-_ ]|第\s{0,4}[\d零一二两三四五六七八九十百千万]{1,6}\s{0,4}[页节]).{0,30}$`,
	}
}

// minChapterGap 是两个「相邻目录命中点」之间至少需要的字符数。
//
// 与 legado TextFile 保持一致（硬编码 1000）：正文里偶尔出现「他翻到第三章」这种
// 句子时，若不加间距约束，一行行文本都会被当成章节标题。
const minChapterGap = 1000

// Parse 解析 TXT 文件，产出元信息与章节结构。
//
// 章节定位采用「字符偏移区间」而非行号：这样取正文时无需重新扫描全文。
func (p *TXTParser) Parse(ctx context.Context, path string) (*port.ParsedBook, error) {
	text, err := readTextFile(path)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(text) == "" {
		return nil, fmt.Errorf("%w: 文件内容为空", domain.ErrParseFailed)
	}

	marks, err := p.locate(text)
	if err != nil {
		return nil, err
	}

	// 一个目录都没识别到时，按字数强制分章，避免整本书变成一章。
	if len(marks) == 0 {
		marks = p.splitByLength(text)
	}

	chapters := make([]*domain.BookChapter, 0, len(marks))
	for i, m := range marks {
		end := len(text)
		if i+1 < len(marks) {
			end = marks[i+1].start
		}
		chapters = append(chapters, &domain.BookChapter{
			Index:    i,
			Title:    m.title,
			Resource: fmt.Sprintf("%d:%d", m.start, end),
		})
	}

	return &port.ParsedBook{
		Chapters: chapters,
		Meta: port.BookMeta{
			Title: titleFromText(text, marks),
		},
	}, nil
}

// Content 按章节的偏移区间取出正文并转为 HTML。
func (p *TXTParser) Content(ctx context.Context, path string, chapter *domain.BookChapter) (*port.ChapterContent, error) {
	text, err := readTextFile(path)
	if err != nil {
		return nil, err
	}
	start, end, err := parseRange(chapter.Resource, len(text))
	if err != nil {
		return nil, err
	}
	body := text[start:end]
	return &port.ChapterContent{
		Title: chapter.Title,
		HTML:  textToHTML(body),
	}, nil
}

// tocMark 是一个目录命中点。
type tocMark struct {
	start int
	title string
}

// locate 扫描全文，找出所有符合目录规则的标题偏移。
//
// 算法对齐 legado TextFile.getTocRule：所有规则各自全文扫描一遍，
// **取命中数最多的那一条规则**作为唯一目录规则，而不是「任一规则命中即收录」。
// 后者会让「1.」「书名 一」这类宽松规则把正文短行也变成章节，准确率极差。
func (p *TXTParser) locate(text string) ([]tocMark, error) {
	if text == "" {
		return nil, nil
	}
	// regexp2 用 rune 下标，全文建一次偏移表供所有规则复用
	offsets := runeOffsets(text)
	gap := chapterGap(len(text))

	best := 0
	var bestMarks []tocMark
	for _, rule := range p.Rules {
		re, err := regexp2.Compile(rule, regexp2.Multiline)
		if err != nil {
			// 单条规则编译失败不应阻断整体，跳过即可。
			continue
		}
		marks := scanTocMarks(text, offsets, re, gap)
		// 命中数最多者胜出；命中数相同则取更靠前出现的规则结果
		// （短文本里「正文」「序章」这类关键词常与真正的章节标题打平，
		//   而书名/首章总在文件开头，取靠前的更接近人工判断）
		switch {
		case len(marks) > best:
			best, bestMarks = len(marks), marks
		case len(marks) == best && len(marks) > 0 && marks[0].start < bestMarks[0].start:
			bestMarks = marks
		}
	}
	if best == 0 {
		return nil, nil
	}
	return bestMarks, nil
}

// chapterGap 返回本次扫描使用的最小章节间距。
//
// legado 硬编码 1000 字符（面向两三千字一章的网文）。短篇或测试文本里一章可能
// 只有几十字，硬阈值会把后续章节全滤掉，因此按全文长度缩放，1000 为上界。
func chapterGap(textLen int) int {
	gap := textLen / 50
	if gap > minChapterGap {
		gap = minChapterGap
	}
	if gap < 1 {
		gap = 1
	}
	return gap
}

// scanTocMarks 用单条规则全文扫描，返回命中点（按最小间距过滤）。
func scanTocMarks(text string, offsets []int, re *regexp2.Regexp, gap int) []tocMark {
	m, err := re.FindStringMatch(text)
	if err != nil || m == nil {
		return nil
	}
	var marks []tocMark
	lastEnd := 0
	for m != nil {
		start := byteOffset(offsets, m.RuneIndex)
		end := byteOffset(offsets, m.RuneIndex+m.RuneLength)
		// 与 legado 一致：两个标题挨得太近时，后一个视为正文里的误命中
		if len(marks) == 0 || start-lastEnd > gap {
			lineStart := lineStartOf(text, start)
			title := strings.TrimSpace(text[lineStart:end])
			if title != "" {
				marks = append(marks, tocMark{start: lineStart, title: title})
				lastEnd = end
			}
		}
		if m, err = re.FindNextMatch(m); err != nil {
			break
		}
	}
	return marks
}

// runeOffsets 构造 rune 下标 → 字节偏移 的映射表，末位补上字符串长度。
func runeOffsets(s string) []int {
	t := make([]int, 0, len(s)+1)
	for i := range s {
		t = append(t, i)
	}
	return append(t, len(s))
}

// byteOffset 把 regexp2 的 rune 下标换成字节偏移，越界时夹到末尾。
func byteOffset(offsets []int, runeIdx int) int {
	switch {
	case runeIdx <= 0:
		return 0
	case runeIdx >= len(offsets):
		return offsets[len(offsets)-1]
	}
	return offsets[runeIdx]
}

// lineStartOf 返回 byteIdx 所在行的行首字节偏移。
func lineStartOf(text string, byteIdx int) int {
	if byteIdx <= 0 {
		return 0
	}
	if byteIdx > len(text) {
		byteIdx = len(text)
	}
	if i := strings.LastIndexByte(text[:byteIdx], '\n'); i >= 0 {
		return i + 1
	}
	return 0
}

// splitLines 按 \n 切分，统一处理 \r\n。
func splitLines(text string) []string {
	normalized := strings.ReplaceAll(text, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	return strings.Split(normalized, "\n")
}

// splitByLength 在识别不到目录时按固定字数切分。
func (p *TXTParser) splitByLength(text string) []tocMark {
	size := p.MaxChapterChars
	if size <= 0 {
		size = 5000
	}
	var marks []tocMark
	for i := 0; i < len(text); i += size {
		marks = append(marks, tocMark{
			start: i,
			title: fmt.Sprintf("第 %d 节", len(marks)+1),
		})
	}
	if len(marks) == 0 {
		marks = append(marks, tocMark{start: 0, title: "正文"})
	}
	return marks
}

// titleFromText 推断书名：优先用首个目录前的非空行，否则用首行。
func titleFromText(text string, marks []tocMark) string {
	head := text
	if len(marks) > 0 && marks[0].start > 0 {
		head = text[:marks[0].start]
	}
	for _, line := range splitLines(head) {
		if t := strings.TrimSpace(line); t != "" {
			return truncate(t, 80)
		}
	}
	return ""
}

// readTextFile 读取文件并解码为 UTF-8。
//
// 编码检测对**短文本**并不可靠（这是编码检测算法的通病）：
// 一段 GBK 中文被误判为 UTF-8 时，解码结果里会出现 U+FFFD 替换字符。
// 因此这里做一次结果校验：发现替换字符就回退尝试常见中文编码。
func readTextFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("读取文件失败: %w", err)
	}

	charset := legadoutil.DetectCharset("", data)
	text := legadoutil.DecodeBytes(data, charset)

	const replacement = '\uFFFD'
	if strings.ContainsRune(text, replacement) {
		for _, alt := range []string{"gb18030", "gbk", "big5"} {
			if alt == charset {
				continue
			}
			decoded := legadoutil.DecodeBytes(data, alt)
			if decoded != "" && !strings.ContainsRune(decoded, replacement) {
				text = decoded
				break
			}
		}
	}

	// 解码失败（返回空）时回退为按 UTF-8 原样读取，保证不至于完全打不开。
	if text == "" {
		text = string(data)
	}
	return strings.ReplaceAll(text, "\r\n", "\n"), nil
}

// parseRange 解析 "start:end" 形式的偏移区间，并做边界校验。
func parseRange(resource string, total int) (int, int, error) {
	parts := strings.Split(resource, ":")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("%w: 章节定位信息无效: %q", domain.ErrParseFailed, resource)
	}
	start, err := strconv.Atoi(parts[0])
	if err != nil {
		return 0, 0, fmt.Errorf("%w: 起始偏移无效", domain.ErrParseFailed)
	}
	end, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, 0, fmt.Errorf("%w: 结束偏移无效", domain.ErrParseFailed)
	}
	if start < 0 || end > total || start > end {
		return 0, 0, fmt.Errorf("%w: 偏移越界", domain.ErrParseFailed)
	}
	return start, end, nil
}

// textToHTML 把纯文本正文转成 HTML 段落。
func textToHTML(body string) string {
	var buf strings.Builder
	buf.WriteString(`<div class="txt-content">`)
	for _, line := range splitLines(body) {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		buf.WriteString("<p>")
		buf.WriteString(escapeHTML(trimmed))
		buf.WriteString("</p>")
	}
	buf.WriteString("</div>")
	return buf.String()
}

// escapeHTML 转义 HTML 特殊字符。
func escapeHTML(s string) string {
	replacer := strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
		`"`, "&quot;",
	)
	return replacer.Replace(s)
}

// truncate 截断字符串到指定长度。
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// bytesReader 把字节切片包装为 io.ReadCloser，用于封面等二进制资源。
func bytesReader(b []byte) io.ReadCloser {
	return io.NopCloser(bytes.NewReader(b))
}
