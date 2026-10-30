package util

import (
	"bytes"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

var (
	htmlEntities = map[string]string{
		"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
		"nbsp": "\u00a0", "iexcl": "\u00a1", "cent": "\u00a2", "pound": "\u00a3",
		"curren": "\u00a4", "yen": "\u00a5", "brvbar": "\u00a6", "sect": "\u00a7",
		"copy": "\u00a9", "reg": "\u00ae", "deg": "\u00b0", "plusmn": "\u00b1",
		"times": "\u00d7", "divide": "\u00f7", "hellip": "\u2026", "mdash": "\u2014",
		"ndash": "\u2013", "lsquo": "\u2018", "rsquo": "\u2019", "ldquo": "\u201c",
		"rdquo": "\u201d", "bull": "\u2022", "trade": "\u2122", "euro": "\u20ac",
		"larr": "\u2190", "rarr": "\u2192", "uarr": "\u2191", "darr": "\u2193",
		"Alpha": "\u0391", "Beta": "\u0392", "Gamma": "\u0393", "pi": "\u03c0",
	}
	entityRe = regexp.MustCompile(`&(#x?[0-9a-fA-F]+|[a-zA-Z]+);`)
)

// UnescapeHtml4 对齐 Apache commons-text StringEscapeUtils.unescapeHtml4 的常用子集
func UnescapeHtml4(s string) string {
	if !strings.Contains(s, "&") {
		return s
	}
	return entityRe.ReplaceAllStringFunc(s, func(m string) string {
		inner := m[1 : len(m)-1]
		if strings.HasPrefix(inner, "#") {
			num := inner[1:]
			base := 10
			if strings.HasPrefix(strings.ToLower(num), "x") {
				num = num[1:]
				base = 16
			}
			if n, err := strconv.ParseInt(num, base, 32); err == nil && n >= 0 {
				return string(rune(n))
			}
			return m
		}
		if v, ok := htmlEntities[inner]; ok {
			return v
		}
		if v, ok := htmlEntities[strings.ToLower(inner)]; ok {
			return v
		}
		return m
	})
}

// ParseHTML 把 HTML 字符串解析成文档根节点。
//
// 对应 jsoup 的 Jsoup.parse：书源 JS 里常见
// `var doc = org.jsoup.Jsoup.parse(java.ajax(url))`，拿到可 select 的文档。
func ParseHTML(s string) (*html.Node, error) {
	return html.Parse(strings.NewReader(s))
}

// Render 将节点渲染为 HTML
func Render(n *html.Node) string {
	if n == nil {
		return ""
	}
	var buf bytes.Buffer
	if err := html.Render(&buf, n); err != nil {
		return ""
	}
	return buf.String()
}

// OuterHTML 节点自身及子节点
func OuterHTML(n *html.Node) string { return Render(n) }

// InnerHTML 仅子节点
func InnerHTML(n *html.Node) string {
	if n == nil {
		return ""
	}
	var buf bytes.Buffer
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		_ = html.Render(&buf, c)
	}
	return buf.String()
}

// NodeText 节点及后代的全部文本
func NodeText(n *html.Node) string {
	if n == nil {
		return ""
	}
	var sb strings.Builder
	var walk func(*html.Node)
	walk = func(x *html.Node) {
		if x.Type == html.TextNode {
			sb.WriteString(x.Data)
		}
		for c := x.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(n)
	return sb.String()
}

// NodeOwnText 仅直接文本子节点
func NodeOwnText(n *html.Node) string {
	if n == nil {
		return ""
	}
	var sb strings.Builder
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type == html.TextNode {
			sb.WriteString(c.Data)
		}
	}
	return sb.String()
}

// blockTags jsoup 视为块级、在 text() 里需要补空格的标签。
// jsoup 的 `Element.text()` 会折叠空白并 trim，同时块级元素之间补一个空格；
// 少了这一步，`<li> A1 </li>` 会取到 " A1 "，章节名带换行缩进、去重键失真。
var blockTags = map[string]bool{
	"address": true, "article": true, "aside": true, "blockquote": true,
	"br": true, "dd": true, "div": true, "dl": true, "dt": true,
	"fieldset": true, "figcaption": true, "figure": true, "footer": true,
	"form": true, "h1": true, "h2": true, "h3": true, "h4": true, "h5": true,
	"h6": true, "header": true, "hr": true, "li": true, "main": true,
	"nav": true, "ol": true, "p": true, "pre": true, "section": true,
	"table": true, "tbody": true, "td": true, "tfoot": true, "th": true,
	"thead": true, "tr": true, "ul": true,
}

// NodeTextNorm 对齐 jsoup `Element.text()`：块级边界补空格、折叠空白、trim。
// 这是 `@text` / JS `element.text()` 的取值口径，`data()` 仍走 NodeText。
func NodeTextNorm(n *html.Node) string {
	if n == nil {
		return ""
	}
	var sb strings.Builder
	var walk func(*html.Node)
	walk = func(x *html.Node) {
		if x.Type == html.TextNode {
			sb.WriteString(x.Data)
			return
		}
		block := x.Type == html.ElementNode && blockTags[strings.ToLower(x.Data)]
		if block {
			sb.WriteByte(' ')
		}
		for c := x.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
		if block {
			sb.WriteByte(' ')
		}
	}
	walk(n)
	return collapseSpace(sb.String())
}

// NodeOwnTextNorm 对齐 jsoup `Element.ownText()`：只取直接文本子节点，
// 折叠空白并 trim（`<br>` 视作一个空格）。
func NodeOwnTextNorm(n *html.Node) string {
	if n == nil {
		return ""
	}
	var sb strings.Builder
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		switch c.Type {
		case html.TextNode:
			sb.WriteString(c.Data)
		case html.ElementNode:
			if strings.EqualFold(c.Data, "br") {
				sb.WriteByte(' ')
			}
		}
	}
	return collapseSpace(sb.String())
}

// collapseSpace 把连续空白（含 &nbsp;）折叠成单个空格并 trim
func collapseSpace(s string) string {
	if s == "" {
		return ""
	}
	return strings.Join(strings.Fields(s), " ")
}

// NodeTextNodes 直接文本子节点列表（已 trim，去空）
func NodeTextNodes(n *html.Node) []string {
	var out []string
	if n == nil {
		return out
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type == html.TextNode {
			t := strings.TrimSpace(c.Data)
			if t != "" {
				out = append(out, t)
			}
		}
	}
	return out
}

// NodeAttr 取属性值，支持 abs:href / abs:src 之外的普通属性
func NodeAttr(n *html.Node, name string) string {
	if n == nil {
		return ""
	}
	name = strings.ToLower(name)
	for _, a := range n.Attr {
		if strings.ToLower(a.Key) == name {
			return a.Val
		}
	}
	return ""
}

// ChildElements 元素子节点
func ChildElements(n *html.Node) []*html.Node {
	var out []*html.Node
	if n == nil {
		return out
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type == html.ElementNode {
			out = append(out, c)
		}
	}
	return out
}

// Descendants 后代元素（不含自身）
func Descendants(n *html.Node) []*html.Node {
	var out []*html.Node
	var walk func(*html.Node)
	walk = func(x *html.Node) {
		for c := x.FirstChild; c != nil; c = c.NextSibling {
			if c.Type == html.ElementNode {
				out = append(out, c)
				walk(c)
			}
		}
	}
	walk(n)
	return out
}

// RemoveNodes 从父节点中移除匹配选择器的后代（用于 html 规则剔除 script/style）
func RemoveNodes(root *html.Node, tagNames ...string) {
	set := map[string]bool{}
	for _, t := range tagNames {
		set[strings.ToLower(t)] = true
	}
	var walk func(*html.Node)
	walk = func(x *html.Node) {
		var next *html.Node
		for c := x.FirstChild; c != nil; c = next {
			next = c.NextSibling
			if c.Type == html.ElementNode && set[strings.ToLower(c.Data)] {
				x.RemoveChild(c)
				continue
			}
			walk(c)
		}
	}
	if root != nil {
		walk(root)
	}
}

// StripTags 移除指定标签后返回 outerHtml（对齐 legado getResultLast 的 html 分支）
func StripTagsOuterHTML(nodes []*html.Node) string {
	var sb strings.Builder
	for _, n := range nodes {
		cp := CloneNode(n)
		RemoveNodes(cp, "script", "style")
		sb.WriteString(Render(cp))
	}
	return sb.String()
}

// CloneNode 深拷贝节点
func CloneNode(n *html.Node) *html.Node {
	if n == nil {
		return nil
	}
	cp := &html.Node{
		Type:     n.Type,
		DataAtom: n.DataAtom,
		Data:     n.Data,
		Attr:     append([]html.Attribute(nil), n.Attr...),
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		cp.AppendChild(CloneNode(c))
	}
	return cp
}

// 以下正则对齐 legado app/utils/HtmlFormatter.kt
var (
	nbspRe     = regexp.MustCompile(`(&nbsp;)+`)
	espRe      = regexp.MustCompile(`(&ensp;|&emsp;)`)
	noPrintRe  = regexp.MustCompile("(&thinsp;|&zwnj;|&zwj;|\u2009|\u200C|\u200D)")
	wrapHTMLRe = regexp.MustCompile(`(?i)</?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>`)
	commentRe  = regexp.MustCompile(`<!--[^>]*-->`)
	// legado 为 `</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>` / `</?[a-zA-Z]+(?=[ >])[^<>]*>`，
	// RE2 不支持前瞻，改为匹配全部标签后再按标签名过滤，结果等价。
	anyTagRe  = regexp.MustCompile(`(?i)</?[a-zA-Z]+[^<>]*>`)
	indent1Re = regexp.MustCompile(`\s*\n+\s*`)
	indent2Re = regexp.MustCompile(`^[\n\s]+`)
	lastRe    = regexp.MustCompile(`[\n\s]+$`)

	// legado 用一条大正则（formatImagePattern）取 img 地址，其中含嵌套大括号分支；
	// RE2 对这类模式会给出最短匹配，与 Java 不一致，故改为先取标签、再手工解析属性。
	imgTagRe = regexp.MustCompile(`(?is)<img\b[^>]*>`)
)

// HtmlFormat 正文/简介格式化（对齐 legado HtmlFormatter.format）：
// 去注释与标签、块级标签转换行、行首缩进两个全角空格
func HtmlFormat(s string) string {
	return htmlFormat(s, false, "")
}

// FormatKeepImg 正文格式化，保留 <img> 并按 redirectUrl 补全相对地址
// （对齐 legado HtmlFormatter.formatKeepImg）
func FormatKeepImg(s, redirectUrl string) string {
	return htmlFormat(s, true, redirectUrl)
}

func htmlFormat(s string, keepImg bool, redirectUrl string) string {
	out := nbspRe.ReplaceAllString(s, " ")
	out = espRe.ReplaceAllString(out, " ")
	out = noPrintRe.ReplaceAllString(out, "")
	out = wrapHTMLRe.ReplaceAllString(out, "\n")
	out = commentRe.ReplaceAllString(out, "")
	out = removeTags(out, keepImg)
	out = indent1Re.ReplaceAllString(out, "\n　　")
	out = indent2Re.ReplaceAllString(out, "　　")
	out = lastRe.ReplaceAllString(out, "")
	if keepImg {
		out = normalizeImages(out, redirectUrl)
	}
	return out
}

// removeTags 移除标签；keepImg 时保留 <img>
func removeTags(s string, keepImg bool) string {
	return anyTagRe.ReplaceAllStringFunc(s, func(m string) string {
		start := 1
		if strings.HasPrefix(m, "</") {
			start = 2
		}
		name, ok := tagNameAfter(m, start)
		if !ok {
			return m
		}
		if keepImg && strings.EqualFold(name, "img") {
			return m
		}
		return ""
	})
}

// tagNameAfter 取出 m 中 start 位置起的标签名，并校验其后的边界字符
// （复现 legado 正则中的 `[a-zA-Z]+(?=[ >])` 前瞻语义）
func tagNameAfter(m string, start int) (string, bool) {
	i := start
	for i < len(m) {
		c := m[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			i++
			continue
		}
		break
	}
	if i == start || i >= len(m) {
		return "", false
	}
	if m[i] != ' ' && m[i] != '>' {
		return "", false
	}
	return m[start:i], true
}

// normalizeImages 把 <img> 统一成 <img src="绝对地址[\,URL选项]">
func normalizeImages(s, redirectUrl string) string {
	locs := imgTagRe.FindAllStringIndex(s, -1)
	if len(locs) == 0 {
		return s
	}
	var sb strings.Builder
	appendPos := 0
	for _, loc := range locs {
		raw, hasRule, ok := imgSrcOf(s[loc[0]:loc[1]])
		if !ok {
			continue // 取不到地址则原样保留
		}
		param := ""
		if hasRule {
			raw, param = splitURLParam(raw)
		}
		sb.WriteString(s[appendPos:loc[0]])
		sb.WriteString(`<img src="`)
		sb.WriteString(GetAbsoluteURL(redirectUrl, raw))
		sb.WriteString(param)
		sb.WriteString(`">`)
		appendPos = loc[1]
	}
	if appendPos < len(s) {
		sb.WriteString(s[appendPos:])
	}
	return sb.String()
}

// imgSrcOf 按 legado formatImagePattern 的优先级取图片地址：
// 1) src 里带 {...} 规则；2) data-src / src（文档序靠前者）；3) 其它 data-*
func imgSrcOf(tag string) (raw string, hasRule bool, ok bool) {
	attrs := parseTagAttrs(tag)
	for _, a := range attrs {
		if strings.EqualFold(a.name, "src") && strings.Contains(a.val, "{") && a.val != "" {
			return a.val, true, true
		}
	}
	for _, a := range attrs {
		if strings.EqualFold(a.name, "data-src") || strings.EqualFold(a.name, "src") {
			if a.val != "" {
				return a.val, false, true
			}
		}
	}
	for _, a := range attrs {
		if strings.HasPrefix(strings.ToLower(a.name), "data-") && a.val != "" {
			return a.val, false, true
		}
	}
	return "", false, false
}

// splitURLParam 拆出地址里的 URL 选项：`url,{"headers":...}` →
// 返回 (url, `,{"headers":...}`)，对齐 legado AnalyzeUrl.paramPattern（`\s*,\s*(?=\{)`）
func splitURLParam(raw string) (string, string) {
	for i := 0; i < len(raw); i++ {
		if raw[i] != ',' {
			continue
		}
		j := i + 1
		for j < len(raw) && isSpaceByte(raw[j]) {
			j++
		}
		if j < len(raw) && raw[j] == '{' {
			k := i
			for k > 0 && isSpaceByte(raw[k-1]) {
				k--
			}
			return raw[:k], "," + raw[j:]
		}
	}
	return raw, ""
}

type tagAttr struct{ name, val string }

func parseTagAttrs(tag string) []tagAttr {
	var out []tagAttr
	i := 0
	for i < len(tag) && !isSpaceByte(tag[i]) && tag[i] != '>' {
		i++ // 跳过标签名
	}
	for i < len(tag) {
		for i < len(tag) && isSpaceByte(tag[i]) {
			i++
		}
		if i >= len(tag) || tag[i] == '>' || tag[i] == '/' {
			break
		}
		start := i
		for i < len(tag) && !isSpaceByte(tag[i]) && tag[i] != '=' && tag[i] != '>' {
			i++
		}
		name := tag[start:i]
		for i < len(tag) && isSpaceByte(tag[i]) {
			i++
		}
		val := ""
		if i < len(tag) && tag[i] == '=' {
			i++
			for i < len(tag) && isSpaceByte(tag[i]) {
				i++
			}
			if i < len(tag) && (tag[i] == '"' || tag[i] == '\'') {
				q := tag[i]
				i++
				vs := i
				for i < len(tag) && tag[i] != q {
					i++
				}
				val = tag[vs:i]
				if i < len(tag) {
					i++
				}
			} else {
				vs := i
				for i < len(tag) && !isSpaceByte(tag[i]) && tag[i] != '>' {
					i++
				}
				val = tag[vs:i]
			}
		}
		out = append(out, tagAttr{name: name, val: val})
	}
	return out
}

func isSpaceByte(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}
