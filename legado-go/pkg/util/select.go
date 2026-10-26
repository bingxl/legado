package util

import (
	"strings"

	"github.com/PuerkitoBio/goquery"
	"golang.org/x/net/html"
)

// Select 在单个节点内按 CSS 选择器取后代元素
func Select(root *html.Node, css string) []*html.Node {
	return SelectAll([]*html.Node{root}, css)
}

// SelectAll 在多个节点内按 CSS 选择器取后代元素（去重、保序）
func SelectAll(roots []*html.Node, css string) []*html.Node {
	if len(roots) == 0 {
		return nil
	}
	css = strings.TrimSpace(css)
	if css == "" {
		return nil
	}
	out := make([]*html.Node, 0, 8)
	seen := map[*html.Node]bool{}
	for _, r := range roots {
		if r == nil {
			continue
		}
		doc := goquery.NewDocumentFromNode(r)
		sel := doc.Selection
		if strings.TrimSpace(css) == "*" {
			sel.Children().Each(func(_ int, s *goquery.Selection) {
				for _, n := range s.Nodes {
					if !seen[n] {
						seen[n] = true
						out = append(out, n)
					}
				}
			})
			continue
		}
		sel.Find(css).Each(func(_ int, s *goquery.Selection) {
			for _, n := range s.Nodes {
				if !seen[n] {
					seen[n] = true
					out = append(out, n)
				}
			}
		})
	}
	return out
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
	out := Select(root, css)
	doc := goquery.NewDocumentFromNode(root)
	if doc.Is(css) {
		if len(out) == 0 || out[0] != root {
			out = append([]*html.Node{root}, out...)
		}
	}
	return out
}
