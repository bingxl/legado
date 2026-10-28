package rule

import (
	"slices"
	"strconv"
	"strings"

	"github.com/legado/legado-go/pkg/util"
	"golang.org/x/net/html"
)

// 本文件对齐 legado 的 AnalyzeByJSoup.kt

// jsoupSourceRule 处理 @CSS: 前缀
type jsoupSourceRule struct {
	isCss        bool
	elementsRule string
}

func parseJsoupSourceRule(ruleStr string) jsoupSourceRule {
	if len(ruleStr) >= 5 && strings.EqualFold(ruleStr[:5], "@css:") {
		return jsoupSourceRule{true, strings.TrimSpace(ruleStr[5:])}
	}
	return jsoupSourceRule{false, ruleStr}
}

// JsoupGetStringList 取文本列表
func JsoupGetStringList(roots []*html.Node, ruleStr string) []string {
	out := []string{}
	r := parseJsoupSourceRule(ruleStr)
	if r.elementsRule == "" {
		for _, n := range roots {
			if n != nil {
				out = append(out, util.NodeText(n))
			}
		}
		return out
	}
	typ, parts := SplitCombinator(r.elementsRule, "&&", "||", "%%")
	results := make([][]string, 0, len(parts))
	for _, p := range parts {
		var temp []string
		if r.isCss {
			sel, last := splitCssLast(p)
			temp = getResultLast(util.SelectAll(roots, sel), last)
		} else {
			temp = getResultList(roots, p)
		}
		if len(temp) > 0 {
			results = append(results, temp)
			if typ == "||" {
				break
			}
		}
	}
	return mergeStringLists(typ, results)
}

// JsoupGetElements 取元素列表
func JsoupGetElements(roots []*html.Node, ruleStr string) []*html.Node {
	out := []*html.Node{}
	if strings.TrimSpace(ruleStr) == "" {
		return out
	}
	r := parseJsoupSourceRule(ruleStr)
	typ, parts := SplitCombinator(r.elementsRule, "&&", "||", "%%")
	lists := make([][]*html.Node, 0, len(parts))
	for _, p := range parts {
		var el []*html.Node
		if r.isCss {
			sel, _ := splitCssLast(p)
			el = util.SelectAll(roots, sel)
		} else {
			rs := SplitTopLevel(Trim(p), "@")
			if len(rs) > 1 {
				el = roots
				for _, rl := range rs {
					es := make([]*html.Node, 0, len(el))
					for _, et := range el {
						es = append(es, elementsSingle(et, rl)...)
					}
					el = es
				}
			} else {
				for _, et := range roots {
					el = append(el, elementsSingle(et, p)...)
				}
			}
		}
		lists = append(lists, el)
		if len(el) > 0 && typ == "||" {
			break
		}
	}
	return mergeNodeLists(typ, lists)
}

// splitCssLast 按最后一个 '@' 拆分为选择器与取值关键字
func splitCssLast(p string) (string, string) {
	i := strings.LastIndex(p, "@")
	if i < 0 {
		return p, "text"
	}
	return p[:i], p[i+1:]
}

// getResultList 按 "@" 逐层选取元素，最后一段作为取值关键字
func getResultList(roots []*html.Node, ruleStr string) []string {
	parts := SplitTopLevel(Trim(ruleStr), "@")
	if len(parts) == 0 {
		return nil
	}
	// 单段：可能是取值关键字、元素规则，或**属性名**
	// （对齐 legado getResultList：单段时 elements 不筛选，直接交给 getResultLast，
	//  因此 `chapterUrl: "href"` 这类写法取的是当前元素的属性）
	if len(parts) == 1 {
		seg := parts[0]
		if isValueKeyword(seg) || !isSelectorRule(seg) {
			return getResultLast(roots, seg)
		}
		es := make([]*html.Node, 0, len(roots))
		for _, et := range roots {
			es = append(es, elementsSingle(et, seg)...)
		}
		return getResultLast(es, "text")
	}
	nodes := roots
	for i := 0; i < len(parts)-1; i++ {
		es := make([]*html.Node, 0, len(nodes))
		for _, et := range nodes {
			es = append(es, elementsSingle(et, parts[i])...)
		}
		nodes = es
		if len(nodes) == 0 {
			return nil
		}
	}
	return getResultLast(nodes, parts[len(parts)-1])
}

// isValueKeyword 判断是否取值关键字（而非元素选择器）
func isValueKeyword(s string) bool {
	switch strings.TrimSpace(s) {
	case "text", "textNodes", "ownText", "html", "all":
		return true
	}
	return false
}

// selectorPrefixes legado 的 ElementsSingle 选择器前缀（class./tag./id./text./ownText.）
var selectorPrefixes = []string{"class.", "tag.", "id.", "text.", "ownText.", "children", "css:"}

// isSelectorRule 判断单段规则是「元素选择器」还是「属性名」。
// 属性名不会包含空白、索引符号或选择器前缀，据此区分：
//   - `href` / `title` / `src`      → 属性名（走 getResultLast 的 attr 分支）
//   - `text.最新章节` / `class.on`   → 元素选择器
//   - `.item` / `tag.a[0]` / `a > b` → 元素选择器
func isSelectorRule(s string) bool {
	s = strings.TrimSpace(s)
	if s == "" {
		return false
	}
	if strings.ContainsAny(s, " []!>") {
		return true
	}
	// CSS 选择符（.class / #id）与 legado 的选择器前缀
	if strings.HasPrefix(s, ".") || strings.HasPrefix(s, "#") {
		return true
	}
	for _, p := range selectorPrefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

// getResultLast 根据最后一段规则取值
func getResultLast(nodes []*html.Node, lastRule string) []string {
	out := []string{}
	kw := strings.TrimSpace(lastRule)
	switch kw {
	case "text":
		for _, n := range nodes {
			if t := util.NodeText(n); t != "" {
				out = append(out, t)
			}
		}
	case "textNodes":
		for _, n := range nodes {
			if tn := util.NodeTextNodes(n); len(tn) > 0 {
				out = append(out, strings.Join(tn, "\n"))
			}
		}
	case "ownText":
		for _, n := range nodes {
			if t := util.NodeOwnText(n); t != "" {
				out = append(out, t)
			}
		}
	case "html":
		if s := util.StripTagsOuterHTML(nodes); s != "" {
			out = append(out, s)
		}
	case "all":
		if s := renderAll(nodes); s != "" {
			out = append(out, s)
		}
	default:
		for _, n := range nodes {
			v := util.NodeAttr(n, kw)
			if strings.TrimSpace(v) == "" {
				continue
			}
			if !slices.Contains(out, v) {
				out = append(out, v)
			}
		}
	}
	return out
}

func renderAll(nodes []*html.Node) string {
	var sb strings.Builder
	for _, n := range nodes {
		sb.WriteString(util.Render(n))
	}
	return sb.String()
}

// —— ElementsSingle：索引筛选 ——

type indexItem struct {
	isRange bool
	single  int
	start   *int
	end     *int
	step    int
}

type indexSpec struct {
	split        byte // '.' 选择 / '!' 排除 / ' ' 不筛选
	beforeRule   string
	indexDefault []int
	indexes      []indexItem
}

func elementsSingle(temp *html.Node, rule string) []*html.Node {
	es := findIndexSet(rule)
	elements := es.baseElements(temp)
	if es.split == ' ' || (len(es.indexes) == 0 && len(es.indexDefault) == 0) {
		return elements
	}
	n := len(elements)
	if n == 0 {
		return elements
	}
	indexSet := make([]int, 0, n)
	seen := map[int]bool{}

	add := func(i int) {
		if i >= 0 && i < n && !seen[i] {
			seen[i] = true
			indexSet = append(indexSet, i)
		}
	}

	if len(es.indexes) > 0 {
		for _, it := range es.indexes {
			if !it.isRange {
				v := it.single
				if v >= 0 && v < n {
					add(v)
				} else if v < 0 && n >= -v {
					add(v + n)
				}
				continue
			}
			start := 0
			if it.start != nil {
				start = *it.start
			}
			if start < 0 {
				start += n
			}
			end := n - 1
			if it.end != nil {
				end = *it.end
			}
			if end < 0 {
				end += n
			}
			if (start < 0 && end < 0) || (start >= n && end >= n) {
				continue
			}
			if start >= n {
				start = n - 1
			} else if start < 0 {
				start = 0
			}
			if end >= n {
				end = n - 1
			} else if end < 0 {
				end = 0
			}
			step := it.step
			if step == 0 {
				step = 1
			}
			if start == end || step >= n {
				add(start)
				continue
			}
			if step < 0 && -step < n {
				step += n
			}
			if step <= 0 {
				step = 1
			}
			if end > start {
				for i := start; i <= end; i += step {
					add(i)
				}
			} else {
				for i := start; i >= end; i += -step {
					add(i)
				}
			}
		}
	} else {
		for _, v := range es.indexDefault {
			if v >= 0 && v < n {
				add(v)
			} else if v < 0 && n >= -v {
				add(v + n)
			}
		}
	}

	if es.split == '!' {
		res := make([]*html.Node, 0, n)
		for i, e := range elements {
			if !seen[i] {
				res = append(res, e)
			}
		}
		return res
	}
	res := make([]*html.Node, 0, len(indexSet))
	for _, i := range indexSet {
		res = append(res, elements[i])
	}
	return res
}

func (es *indexSpec) baseElements(temp *html.Node) []*html.Node {
	if temp == nil {
		return nil
	}
	if es.beforeRule == "" {
		return util.ChildElements(temp)
	}
	rules := strings.Split(es.beforeRule, ".")
	switch rules[0] {
	case "children":
		return util.ChildElements(temp)
	case "class":
		if len(rules) > 1 {
			return byClass(temp, rules[1])
		}
		return nil
	case "tag":
		if len(rules) > 1 {
			return byTag(temp, strings.ToLower(rules[1]))
		}
		return nil
	case "id":
		if len(rules) > 1 {
			return byID(temp, rules[1])
		}
		return nil
	case "text":
		if len(rules) > 1 {
			return byOwnText(temp, rules[1])
		}
		return nil
	}
	return util.Select(temp, es.beforeRule)
}

func byClass(n *html.Node, cls string) []*html.Node {
	out := []*html.Node{}
	for _, d := range util.Descendants(n) {
		if slices.Contains(strings.Fields(util.NodeAttr(d, "class")), cls) {
			out = append(out, d)
		}
	}
	return out
}

func byTag(n *html.Node, tag string) []*html.Node {
	out := []*html.Node{}
	for _, d := range util.Descendants(n) {
		if strings.ToLower(d.Data) == tag {
			out = append(out, d)
		}
	}
	return out
}

func byID(n *html.Node, id string) []*html.Node {
	out := []*html.Node{}
	for _, d := range util.Descendants(n) {
		if util.NodeAttr(d, "id") == id {
			out = append(out, d)
		}
	}
	return out
}

func byOwnText(n *html.Node, text string) []*html.Node {
	out := []*html.Node{}
	for _, d := range util.Descendants(n) {
		if strings.Contains(util.NodeOwnText(d), text) {
			out = append(out, d)
		}
	}
	return out
}

// findIndexSet 解析规则尾部的索引写法
// 支持：[0] [-1] [0:3] [1,3] [-1:0] [3:-2:-10] 以及旧式 tag.div.0 / tag.div!0:3
func findIndexSet(rule string) *indexSpec {
	es := &indexSpec{split: ' ', beforeRule: rule}
	rus := strings.TrimSpace(rule)
	if rus == "" {
		return es
	}
	// —— 新式：[...] 索引 ——
	if strings.HasSuffix(rus, "]") {
		body := rus[:len(rus)-1]
		li := strings.LastIndex(body, "[")
		if li >= 0 {
			inner := strings.TrimSpace(body[li+1:])
			neg := false
			if strings.HasPrefix(inner, "!") {
				neg = true
				inner = strings.TrimSpace(inner[1:])
			}
			items, ok := parseIndexItems(inner)
			if ok && len(items) > 0 {
				es.beforeRule = body[:li]
				es.indexes = items
				if neg {
					es.split = '!'
				} else {
					es.split = '.'
				}
				return es
			}
		}
		// 非索引结构（如 a[href=x]）→ 整体作为选择器
		return es
	}
	// —— 旧式：. / ! / : 分隔 ——
	l := ""
	curMinus := false
	i := len(rus) - 1
	for i >= 0 {
		c := rus[i]
		if c == ' ' {
			i--
			continue
		}
		if c >= '0' && c <= '9' {
			l = string(c) + l
			i--
			continue
		}
		if c == '-' {
			curMinus = true
			i--
			continue
		}
		if c == '!' || c == '.' || c == ':' {
			if l == "" {
				break
			}
			n, err := strconv.Atoi(l)
			if err != nil {
				break
			}
			if curMinus {
				n = -n
			}
			es.indexDefault = append(es.indexDefault, n)
			if c != ':' {
				es.split = c
				es.beforeRule = rus[:i]
				// indexDefault 是逆序收集的，反转还原书写顺序
				reverseInts(es.indexDefault)
				return es
			}
		} else {
			break
		}
		l = ""
		curMinus = false
		i--
	}
	es.split = ' '
	es.beforeRule = rus
	es.indexDefault = nil
	return es
}

func reverseInts(a []int) {
	for i, j := 0, len(a)-1; i < j; i, j = i+1, j-1 {
		a[i], a[j] = a[j], a[i]
	}
}

func parseIndexItems(inner string) ([]indexItem, bool) {
	if inner == "" {
		return nil, false
	}
	var items []indexItem
	for part := range strings.SplitSeq(inner, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		segs := strings.Split(part, ":")
		if len(segs) > 3 {
			return nil, false
		}
		if len(segs) == 1 {
			n, err := strconv.Atoi(segs[0])
			if err != nil {
				return nil, false
			}
			items = append(items, indexItem{single: n})
			continue
		}
		start := parseOptionalInt(segs[0])
		end := parseOptionalInt(segs[1])
		step := 1
		if len(segs) == 3 {
			step = 1
			if s := parseOptionalInt(segs[2]); s != nil {
				step = *s
			}
		}
		if start == nil && end == nil {
			return nil, false
		}
		items = append(items, indexItem{isRange: true, start: start, end: end, step: step})
	}
	// 反转还原书写顺序
	for i, j := 0, len(items)-1; i < j; i, j = i+1, j-1 {
		items[i], items[j] = items[j], items[i]
	}
	return items, true
}

func parseOptionalInt(s string) *int {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return nil
	}
	return &n
}

// —— 组合结果 ——

func mergeStringLists(typ string, lists [][]string) []string {
	out := []string{}
	if len(lists) == 0 {
		return out
	}
	if typ == "%%" {
		maxLen := 0
		for _, l := range lists {
			if len(l) > maxLen {
				maxLen = len(l)
			}
		}
		for i := 0; i < maxLen; i++ {
			for _, l := range lists {
				if i < len(l) {
					out = append(out, l[i])
				}
			}
		}
		return out
	}
	for _, l := range lists {
		out = append(out, l...)
	}
	return out
}

func mergeNodeLists(typ string, lists [][]*html.Node) []*html.Node {
	out := []*html.Node{}
	if len(lists) == 0 {
		return out
	}
	if typ == "%%" {
		maxLen := 0
		for _, l := range lists {
			if len(l) > maxLen {
				maxLen = len(l)
			}
		}
		for i := 0; i < maxLen; i++ {
			for _, l := range lists {
				if i < len(l) {
					out = append(out, l[i])
				}
			}
		}
		return out
	}
	for _, l := range lists {
		out = append(out, l...)
	}
	return out
}
