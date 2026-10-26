package rule

import (
	"strings"

	"github.com/antchfx/htmlquery"
	"github.com/legado/legado-go/pkg/util"
	"golang.org/x/net/html"
)

// 本文件对齐 legado 的 AnalyzeByXPath.kt

// XPathGetStringList 按 XPath 取文本列表
func XPathGetStringList(content any, xpathRule string) []string {
	out := []string{}
	if strings.TrimSpace(xpathRule) == "" {
		return out
	}
	typ, parts := SplitCombinator(xpathRule, "&&", "||", "%%")
	if len(parts) > 1 && typ != "" {
		results := make([][]string, 0, len(parts))
		for _, p := range parts {
			t := XPathGetStringList(content, p)
			if len(t) > 0 {
				results = append(results, t)
				if typ == "||" {
					break
				}
			}
		}
		return mergeStringLists(typ, results)
	}
	nodes := XPathGetElements(content, xpathRule)
	for _, n := range nodes {
		out = append(out, nodeValue(n))
	}
	return out
}

// XPathGetElements 按 XPath 取节点
func XPathGetElements(content any, xpathRule string) []*html.Node {
	out := []*html.Node{}
	if strings.TrimSpace(xpathRule) == "" {
		return out
	}
	typ, parts := SplitCombinator(xpathRule, "&&", "||", "%%")
	if len(parts) > 1 && typ != "" {
		lists := make([][]*html.Node, 0, len(parts))
		for _, p := range parts {
			t := XPathGetElements(content, p)
			if len(t) > 0 {
				lists = append(lists, t)
				if typ == "||" {
					break
				}
			}
		}
		return mergeNodeLists(typ, lists)
	}
	switch t := content.(type) {
	case *html.Node:
		ns, err := htmlquery.QueryAll(t, xpathRule)
		if err == nil {
			out = append(out, ns...)
		}
	case []*html.Node:
		for _, n := range t {
			ns, err := htmlquery.QueryAll(n, xpathRule)
			if err == nil {
				out = append(out, ns...)
			}
		}
	case string:
		doc, err := html.Parse(strings.NewReader(prepareHTML(t)))
		if err != nil {
			return out
		}
		ns, err := htmlquery.QueryAll(doc, xpathRule)
		if err == nil {
			out = append(out, ns...)
		}
	}
	return out
}

// XPathGetString 取单个字符串（多个结果以 \n 连接）
func XPathGetString(content any, xpathRule string) string {
	list := XPathGetStringList(content, xpathRule)
	if len(list) == 0 {
		return ""
	}
	return strings.Join(list, "\n")
}

// prepareHTML 对齐 AnalyzeByXPath.strToJXDocument 的补全与清洗
func prepareHTML(s string) string {
	s = strings.TrimSpace(s)
	if strings.HasSuffix(s, "</td>") {
		s = "<tr>" + s + "</tr>"
	}
	if strings.HasSuffix(s, "</tr>") || strings.HasSuffix(s, "</tbody>") {
		s = "<table>" + s + "</table>"
	}
	return s
}

// nodeValue 对齐 JXNode.asString()：文本/属性节点取值，元素节点取文本
func nodeValue(n *html.Node) string {
	if n == nil {
		return ""
	}
	if n.Type == html.TextNode || n.Type == html.CommentNode {
		return n.Data
	}
	return util.NodeText(n)
}
