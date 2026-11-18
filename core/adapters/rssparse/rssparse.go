// Package rssparse 解析 RSS 2.0 与 Atom 订阅源。
//
// 只依赖标准库 encoding/xml：订阅源是外部输入，格式非常宽松（CDATA、
// 命名空间前缀随意、日期格式五花八门），用 DOM 库反而要额外处理依赖，
// 而这里只需要「标题/链接/正文/时间」四类字段。
package rssparse

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"
)

// Feed 是解析后的订阅源。字段与两种格式的公共语义对齐，
// 调用方不需要知道自己拿到的是 RSS 还是 Atom。
type Feed struct {
	Title       string
	Link        string
	Description string
	Items       []Item
}

// Item 是订阅源中的一篇文章。
type Item struct {
	Title       string
	Link        string
	Description string
	// Content 是全文；RSS 优先取 content:encoded，Atom 取 content。
	Content string
	Author  string
	PubDate time.Time
}

// Parse 自动识别根节点后分别按 RSS 2.0 / Atom 解析。
func Parse(data []byte) (*Feed, error) {
	// 某些站点会在 XML 声明前带 UTF-8 BOM，xml.Decoder 会直接报错。
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))

	root, err := rootElement(data)
	if err != nil {
		return nil, err
	}
	switch strings.ToLower(root) {
	case "rss":
		return parseRSS(data)
	case "feed":
		return parseAtom(data)
	default:
		return nil, fmt.Errorf("不支持的订阅格式: 根节点 <%s>", root)
	}
}

// rootElement 只读到第一个 StartElement 为止，避免把整份文档解析两遍。
func rootElement(data []byte) (string, error) {
	dec := xml.NewDecoder(bytes.NewReader(data))
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			return "", errors.New("订阅内容为空或不是 XML")
		}
		if err != nil {
			return "", fmt.Errorf("解析 XML 失败: %w", err)
		}
		if se, ok := tok.(xml.StartElement); ok {
			return se.Name.Local, nil
		}
	}
}

type rssDoc struct {
	Channel rssChannel `xml:"channel"`
}

type rssChannel struct {
	Title       string    `xml:"title"`
	Link        string    `xml:"link"`
	Description string    `xml:"description"`
	Items       []rssItem `xml:"item"`
}

type rssItem struct {
	Title       string `xml:"title"`
	Link        string `xml:"link"`
	Description string `xml:"description"`
	Author      string `xml:"author"`
	Creator     string `xml:"http://purl.org/dc/elements/1.1/ creator"`
	Guid        string `xml:"guid"`
	PubDate     string `xml:"pubDate"`
	Content     string `xml:"http://purl.org/rss/1.0/modules/content/ encoded"`
}

func parseRSS(data []byte) (*Feed, error) {
	var doc rssDoc
	if err := xml.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("解析 RSS 失败: %w", err)
	}
	ch := doc.Channel
	feed := &Feed{
		Title:       clean(ch.Title),
		Link:        clean(ch.Link),
		Description: clean(ch.Description),
		Items:       make([]Item, 0, len(ch.Items)),
	}
	for _, it := range ch.Items {
		link := clean(it.Link)
		// 少数源只给 guid；guid 是稳定标识，正好满足入库去重。
		if link == "" {
			link = clean(it.Guid)
		}
		author := clean(it.Author)
		if author == "" {
			author = clean(it.Creator)
		}
		content := clean(it.Content)
		desc := clean(it.Description)
		if content == "" {
			content = desc
		}
		feed.Items = append(feed.Items, Item{
			Title:       clean(it.Title),
			Link:        link,
			Description: desc,
			Content:     content,
			Author:      author,
			PubDate:     parseTime(it.PubDate),
		})
	}
	return feed, nil
}

type atomDoc struct {
	Title    string      `xml:"title"`
	Subtitle string      `xml:"subtitle"`
	Links    []atomLink  `xml:"link"`
	Entries  []atomEntry `xml:"entry"`
}

type atomLink struct {
	Rel  string `xml:"rel,attr"`
	Href string `xml:"href,attr"`
	Type string `xml:"type,attr"`
}

type atomEntry struct {
	ID        string       `xml:"id"`
	Title     string       `xml:"title"`
	Links     []atomLink   `xml:"link"`
	Summary   string       `xml:"summary"`
	Content   string       `xml:"content"`
	Published string       `xml:"published"`
	Updated   string       `xml:"updated"`
	Authors   []atomAuthor `xml:"author"`
}

type atomAuthor struct {
	Name  string `xml:"name"`
	Email string `xml:"email"`
}

func parseAtom(data []byte) (*Feed, error) {
	var doc atomDoc
	if err := xml.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("解析 Atom 失败: %w", err)
	}
	feed := &Feed{
		Title:       clean(doc.Title),
		Link:        pickLink(doc.Links),
		Description: clean(doc.Subtitle),
		Items:       make([]Item, 0, len(doc.Entries)),
	}
	for _, e := range doc.Entries {
		link := pickLink(e.Links)
		// Atom 的 id 通常是永久链接，缺 link 时用它兜底去重。
		if link == "" {
			link = clean(e.ID)
		}
		author := ""
		if len(e.Authors) > 0 {
			author = clean(e.Authors[0].Name)
			if author == "" {
				author = clean(e.Authors[0].Email)
			}
		}
		content := clean(e.Content)
		summary := clean(e.Summary)
		if content == "" {
			content = summary
		}
		pub := e.Published
		if strings.TrimSpace(pub) == "" {
			pub = e.Updated
		}
		feed.Items = append(feed.Items, Item{
			Title:       clean(e.Title),
			Link:        link,
			Description: summary,
			Content:     content,
			Author:      author,
			PubDate:     parseTime(pub),
		})
	}
	return feed, nil
}

// pickLink 按 Atom 语义选文章/站点链接：rel="alternate" 优先，
// 其次无 rel（默认就是 alternate），最后退回任意带 href 的 link。
func pickLink(links []atomLink) string {
	var fallback string
	for _, l := range links {
		href := strings.TrimSpace(l.Href)
		if href == "" {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(l.Rel)) {
		case "", "alternate":
			// 优先 text/html；没有 type 的视作网页链接。
			if l.Type == "" || strings.Contains(strings.ToLower(l.Type), "html") {
				return href
			}
			if fallback == "" {
				fallback = href
			}
		}
		if fallback == "" {
			fallback = href
		}
	}
	return fallback
}

// clean 去掉首尾空白。XML 里的缩进会被当成文本节点，不清理会让标题带换行。
func clean(s string) string { return strings.TrimSpace(s) }

// timeLayouts 覆盖主流订阅源的日期写法。
// RFC1123 系列无法用单一 layout 兼容（星期与月份可能是缩写、日可能不补零），
// 按「最精确到最宽松」的顺序尝试。
var timeLayouts = []string{
	time.RFC3339Nano,
	time.RFC3339,
	time.RFC1123Z,
	time.RFC1123,
	time.RFC822Z,
	time.RFC822,
	"Mon, 2 Jan 2006 15:04:05 -0700",
	"Mon, 2 Jan 2006 15:04:05 MST",
	"2 Jan 2006 15:04:05 -0700",
	"2006-01-02T15:04:05Z0700",
	"2006-01-02 15:04:05",
	"2006-01-02",
}

// parseTime 解析失败时返回零值：时间只用于排序，坏时间不应导致整篇丢弃。
func parseTime(s string) time.Time {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}
	}
	for _, layout := range timeLayouts {
		if t, err := time.Parse(layout, s); err == nil {
			return t
		}
	}
	return time.Time{}
}

// ResolveURL 把订阅条目里的相对链接补成绝对链接。
//
// 入库唯一键是 (source_id, link)，相对链接在不同页面下含义不同，
// 入库前统一成绝对地址，UI 也能直接打开。
func ResolveURL(base, ref string) string {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return ""
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
