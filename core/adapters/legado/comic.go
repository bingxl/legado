package legado

import (
	"net/url"
	"strings"

	legadomodel "github.com/legado/legado-go/pkg/model"
	"golang.org/x/net/html"
)

// 书源类型（对齐 Legado 的 BookSourceType）。
const (
	sourceTypeText  = 0 // 文本
	sourceTypeAudio = 1 // 有声
	sourceTypeImage = 2 // 图片（漫画）
)

// isComicSource 判断书源是否为图片类。
func isComicSource(src *legadomodel.BookSource) bool {
	return src != nil && src.BookSourceType == sourceTypeImage
}

// extractImages 从正文 HTML 里抽出图片地址。
//
// 漫画源的 ruleContent.content 通常直接返回一串 <img src="...">（例如漫蛙漫画解密后拼出来）。
// 阅读器对漫画走图片流渲染，需要结构化地址；纯文本章节返回空切片，走 HTML 渲染。
//
// base 用于把相对地址补全（书源里相对地址很常见）；补不出来时保留原样。
func extractImages(raw, base string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	doc, err := html.Parse(strings.NewReader(raw))
	if err != nil {
		return nil
	}

	var out []string
	seen := make(map[string]struct{})
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.ElementNode && n.Data == "img" {
			for _, a := range n.Attr {
				if !strings.EqualFold(a.Key, "src") {
					continue
				}
				src := strings.TrimSpace(a.Val)
				if src == "" || strings.HasPrefix(src, "data:") {
					break
				}
				src = absoluteURL(base, src)
				if _, dup := seen[src]; dup {
					break
				}
				seen[src] = struct{}{}
				out = append(out, src)
				break
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(doc)
	return out
}

// absoluteURL 把相对地址补全为绝对地址；已是绝对的直接返回。
func absoluteURL(base, ref string) string {
	if ref == "" || base == "" {
		return ref
	}
	if strings.HasPrefix(ref, "http://") || strings.HasPrefix(ref, "https://") || strings.HasPrefix(ref, "//") {
		if strings.HasPrefix(ref, "//") {
			if u, err := url.Parse(base); err == nil && u.Scheme != "" {
				return u.Scheme + ":" + ref
			}
		}
		return ref
	}
	b, err := url.Parse(base)
	if err != nil {
		return ref
	}
	r, err := url.Parse(ref)
	if err != nil {
		return ref
	}
	return b.ResolveReference(r).String()
}
