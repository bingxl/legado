package util

import (
	"regexp"
	"strconv"
	"strings"

	"github.com/PuerkitoBio/goquery"
	"github.com/andybalholm/cascadia"
	"golang.org/x/net/html"
)

// Select 在单个节点内按 CSS 选择器取后代元素
func Select(root *html.Node, css string) []*html.Node {
	return SelectAll([]*html.Node{root}, css)
}

// OnSelectorError 选择器编译失败时的回调，供上层接入调试日志（可为 nil）。
//
// 书源里混入 jsoup 能"宽容解析"、cascadia 却拒绝的选择器很常见
// （例如属性值带空格的 `div[class =a b]`）。这类选择器在 legado 里只是匹配不到，
// 不能让它影响同组的其他选择器，更不能静默失败——所以统一走这个回调报出来。
var OnSelectorError func(sel string, err error)

func reportSelectorError(sel string, err error) {
	if OnSelectorError != nil {
		OnSelectorError(sel, err)
	}
}

// SelectAll 在多个节点内按 CSS 选择器取后代元素（去重、保序）
//
// 除了标准 CSS，还支持 jsoup/jQuery 的索引伪类（legado 书源里大量使用）：
//
//	:gt(n) :lt(n) :eq(n) :first :last :even :odd
//
// 这些伪类是 jsoup 扩展，cascadia（goquery 底层）不认识，直接丢给 goquery 会让
// 整条选择器编译失败并**静默返回 0 个节点**。这里在调用 goquery 之前把它们从
// 选择器尾部摘出来，选中之后再按索引过滤，语义与 jsoup 一致。
//
// 分组选择器（`a,b,c`）逐组求值：任一分组非法只跳过该分组，不牵连其他分组。
// 伪类与分组按 jsoup 语义结合——`:first` 属于逗号前那一个选择器，所以先按逗号
// 拆组、再在每组内部摘伪类，最后合并。
func SelectAll(roots []*html.Node, css string) []*html.Node {
	if len(roots) == 0 {
		return nil
	}
	css = strings.TrimSpace(css)
	if css == "" {
		return nil
	}
	groups := SplitSelectorGroup(css)
	if len(groups) <= 1 {
		return selectGroupAll(roots, css)
	}
	out := make([]*html.Node, 0, 8)
	seen := map[*html.Node]bool{}
	for _, g := range groups {
		for _, n := range selectGroupAll(roots, g) {
			if !seen[n] {
				seen[n] = true
				out = append(out, n)
			}
		}
	}
	return out
}

// selectGroupAll 单个分组（不含顶层逗号）求值：摘尾部伪类 → 选元素 → 应用伪类
func selectGroupAll(roots []*html.Node, css string) []*html.Node {
	sel, filters := splitJsoupPseudo(css)
	return applyPseudoFilters(selectNodes(roots, sel), filters)
}

// selectNodes 单个选择器（不含顶层逗号）求值。编译失败返回空并上报。
func selectNodes(roots []*html.Node, sel string) []*html.Node {
	sel = strings.TrimSpace(sel)
	if sel == "" {
		return nil
	}
	if _, err := cascadia.Compile(sel); err != nil {
		reportSelectorError(sel, err)
		return nil
	}
	out := make([]*html.Node, 0, 8)
	seen := map[*html.Node]bool{}
	for _, r := range roots {
		if r == nil {
			continue
		}
		doc := goquery.NewDocumentFromNode(r)
		s := doc.Selection
		if sel == "*" {
			s.Children().Each(func(_ int, g *goquery.Selection) {
				for _, n := range g.Nodes {
					if !seen[n] {
						seen[n] = true
						out = append(out, n)
					}
				}
			})
			continue
		}
		s.Find(sel).Each(func(_ int, g *goquery.Selection) {
			for _, n := range g.Nodes {
				if !seen[n] {
					seen[n] = true
					out = append(out, n)
				}
			}
		})
	}
	return out
}

// SplitSelectorGroup 按顶层逗号拆分 CSS 分组选择器（`a,b,c`）。
// 方括号、圆括号与引号内的逗号不拆分。
func SplitSelectorGroup(css string) []string {
	css = strings.TrimSpace(css)
	if css == "" {
		return nil
	}
	var (
		groups  []string
		start   int
		depth   int
		quote   byte
		escaped bool
	)
	for i := 0; i < len(css); i++ {
		c := css[i]
		if escaped {
			escaped = false
			continue
		}
		if c == '\\' {
			escaped = true
			continue
		}
		if quote != 0 {
			if c == quote {
				quote = 0
			}
			continue
		}
		switch c {
		case '\'', '"':
			quote = c
		case '(', '[':
			depth++
		case ')', ']':
			if depth > 0 {
				depth--
			}
		case ',':
			if depth == 0 {
				if g := strings.TrimSpace(css[start:i]); g != "" {
					groups = append(groups, g)
				}
				start = i + 1
			}
		}
	}
	if g := strings.TrimSpace(css[start:]); g != "" {
		groups = append(groups, g)
	}
	return groups
}

// SelectWithSelf 在单个节点内选择，包含自身匹配
func SelectWithSelf(root *html.Node, css string) []*html.Node {
	if root == nil {
		return nil
	}
	css = strings.TrimSpace(css)
	if css == "" {
		return nil
	}
	groups := SplitSelectorGroup(css)
	if len(groups) == 0 {
		groups = []string{css}
	}
	all := make([]*html.Node, 0, 8)
	seen := map[*html.Node]bool{}
	add := func(ns []*html.Node) {
		for _, n := range ns {
			if n != nil && !seen[n] {
				seen[n] = true
				all = append(all, n)
			}
		}
	}
	// 组内处理：自身匹配 + 后代匹配，再统一应用该组的伪类
	for _, g := range groups {
		sel, filters := splitJsoupPseudo(g)
		if _, err := cascadia.Compile(sel); err != nil {
			reportSelectorError(sel, err)
			continue
		}
		doc := goquery.NewDocumentFromNode(root)
		var self []*html.Node
		if doc.Is(sel) {
			self = []*html.Node{root}
		}
		self = append(self, selectNodes([]*html.Node{root}, sel)...)
		add(applyPseudoFilters(self, filters))
	}
	return all
}

// —— jsoup 索引伪类 ——

// pseudoChainRe 匹配选择器尾部连续出现的索引伪类
var pseudoChainRe = regexp.MustCompile(`(?::(?:gt|lt|eq)\(\s*[-+]?\d+\s*\)|:(?:first|last|even|odd))+$`)

// pseudoItemRe 从伪类串里逐项拆出名称与参数
var pseudoItemRe = regexp.MustCompile(`:((?:gt|lt|eq)\(\s*([-+]?\d+)\s*\)|first|last|even|odd)`)

type pseudoFilter struct {
	kind string // gt / lt / eq / first / last / even / odd
	n    int
}

// splitJsoupPseudo 摘出尾部的索引伪类，返回剩余选择器与过滤器列表（按书写顺序）
func splitJsoupPseudo(css string) (string, []pseudoFilter) {
	loc := pseudoChainRe.FindStringIndex(css)
	// 整串都是伪类（如 ":gt(0)"）无法单独选元素，原样交给 goquery
	if loc == nil || loc[0] == 0 {
		return css, nil
	}
	chain := css[loc[0]:]
	var filters []pseudoFilter
	for _, m := range pseudoItemRe.FindAllStringSubmatch(chain, -1) {
		name := m[1]
		if before, _, ok := strings.Cut(name, "("); ok {
			n, err := strconv.Atoi(strings.TrimSpace(m[2]))
			if err != nil {
				continue
			}
			filters = append(filters, pseudoFilter{kind: before, n: n})
			continue
		}
		filters = append(filters, pseudoFilter{kind: name})
	}
	return strings.TrimSpace(css[:loc[0]]), filters
}

// applyPseudoFilters 按索引过滤节点集合，多个伪类按书写顺序依次生效（与 jsoup 一致）
func applyPseudoFilters(nodes []*html.Node, filters []pseudoFilter) []*html.Node {
	if len(filters) == 0 {
		return nodes
	}
	for _, f := range filters {
		n := len(nodes)
		out := make([]*html.Node, 0, n)
		for i, nd := range nodes {
			switch f.kind {
			case "gt":
				if i > f.n {
					out = append(out, nd)
				}
			case "lt":
				if i < f.n {
					out = append(out, nd)
				}
			case "eq":
				if i == f.n {
					out = append(out, nd)
				}
			case "first":
				if i == 0 {
					out = append(out, nd)
				}
			case "last":
				if i == n-1 {
					out = append(out, nd)
				}
			case "even":
				if i%2 == 0 {
					out = append(out, nd)
				}
			case "odd":
				if i%2 == 1 {
					out = append(out, nd)
				}
			}
		}
		nodes = out
	}
	return nodes
}
