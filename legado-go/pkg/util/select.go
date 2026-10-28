package util

import (
	"regexp"
	"strconv"
	"strings"

	"github.com/PuerkitoBio/goquery"
	"golang.org/x/net/html"
)

// Select 在单个节点内按 CSS 选择器取后代元素
func Select(root *html.Node, css string) []*html.Node {
	return SelectAll([]*html.Node{root}, css)
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
func SelectAll(roots []*html.Node, css string) []*html.Node {
	if len(roots) == 0 {
		return nil
	}
	css = strings.TrimSpace(css)
	if css == "" {
		return nil
	}
	sel, filters := splitJsoupPseudo(css)
	out := make([]*html.Node, 0, 8)
	seen := map[*html.Node]bool{}
	for _, r := range roots {
		if r == nil {
			continue
		}
		doc := goquery.NewDocumentFromNode(r)
		s := doc.Selection
		if strings.TrimSpace(sel) == "*" {
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
	return applyPseudoFilters(out, filters)
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
	// 自身是否匹配只看去掉索引伪类后的选择器；伪类最后统一作用在合并结果上
	sel, filters := splitJsoupPseudo(css)
	all := make([]*html.Node, 0, 8)
	doc := goquery.NewDocumentFromNode(root)
	if doc.Is(sel) {
		all = append(all, root)
	}
	all = append(all, Select(root, sel)...)
	return applyPseudoFilters(all, filters)
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
