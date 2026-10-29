// Package exporter 把书籍导出为 TXT / EPUB 文件。
//
// 导出流程由 port.BookExporter 定义：调用方传入书籍、章节列表，
// 以及一个「按章节取正文」的回调。回调机制使导出器不必关心正文来自
// 本地文件还是网络书源。
package exporter

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/raitucarp/epub"
	"golang.org/x/net/html"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// TXTExporter 把书籍导出为纯文本。
type TXTExporter struct{}

// NewTXTExporter 创建 TXT 导出器。
func NewTXTExporter() *TXTExporter { return &TXTExporter{} }

var _ port.BookExporter = (*TXTExporter)(nil)

// Format 返回导出格式。
func (e *TXTExporter) Format() domain.BookFormat { return domain.BookFormatTXT }

// Extension 返回文件扩展名。
func (e *TXTExporter) Extension() string { return ".txt" }

// Export 按「书名 / 作者 / 章节标题 / 正文」的顺序写出纯文本。
func (e *TXTExporter) Export(ctx context.Context, w io.Writer, book *domain.Book, chapters []*domain.BookChapter, fetch func(*domain.BookChapter) (*port.ChapterContent, error)) error {
	var buf bytes.Buffer
	buf.WriteString(book.Name)
	buf.WriteString("\n")
	if book.Author != "" {
		buf.WriteString("作者：")
		buf.WriteString(book.Author)
		buf.WriteString("\n")
	}
	buf.WriteString("\n")

	for _, ch := range chapters {
		if err := ctx.Err(); err != nil {
			return err
		}
		buf.WriteString("\n")
		buf.WriteString(ch.Title)
		buf.WriteString("\n\n")

		content, err := fetch(ch)
		if err != nil {
			// 单章取不到内容时写入占位说明，避免整本导出失败。
			buf.WriteString("（本章内容获取失败）\n")
			continue
		}
		buf.WriteString(htmlToText(content.HTML))
		buf.WriteString("\n")
	}

	if _, err := w.Write(buf.Bytes()); err != nil {
		return fmt.Errorf("写入导出内容失败: %w", err)
	}
	return nil
}

// EPUBExporter 把书籍导出为 EPUB 3。
type EPUBExporter struct{}

// NewEPUBExporter 创建 EPUB 导出器。
func NewEPUBExporter() *EPUBExporter { return &EPUBExporter{} }

var _ port.BookExporter = (*EPUBExporter)(nil)

// Format 返回导出格式。
func (e *EPUBExporter) Format() domain.BookFormat { return domain.BookFormatEPUB }

// Extension 返回文件扩展名。
func (e *EPUBExporter) Extension() string { return ".epub" }

// Export 组装 EPUB 并写入 w。
func (e *EPUBExporter) Export(ctx context.Context, w io.Writer, book *domain.Book, chapters []*domain.BookChapter, fetch func(*domain.BookChapter) (*port.ChapterContent, error)) error {
	writer := epub.New(epubUID(book))
	writer.Title(book.Name)
	if book.Author != "" {
		writer.Author(book.Author)
	}
	writer.Languages("zh")

	tocItems := make([]epub.TOC, 0, len(chapters))
	for i, ch := range chapters {
		if err := ctx.Err(); err != nil {
			return err
		}
		name := fmt.Sprintf("chapter-%04d.xhtml", i+1)

		content, err := fetch(ch)
		body := ""
		if err == nil {
			body = content.HTML
		} else {
			body = "<p>（本章内容获取失败）</p>"
		}

		// 网络书源的 HTML 常常不规范，先解析再渲染，
		// 顺带得到自闭合标签，满足 XHTML 要求。
		xhtml := wrapXHTML(ch.Title, normalizeHTML(body))
		writer.AddContent(name, []byte(xhtml))
		tocItems = append(tocItems, epub.TOC{Title: ch.Title, Href: name})
	}

	if err := writer.TableOfContents("toc", epub.TOC{Title: "目录", Items: tocItems}); err != nil {
		return fmt.Errorf("生成目录失败: %w", err)
	}

	data, err := writer.WriteBytes()
	if err != nil {
		return fmt.Errorf("生成 EPUB 失败: %w", err)
	}
	if _, err := w.Write(data); err != nil {
		return fmt.Errorf("写入导出内容失败: %w", err)
	}
	return nil
}

// epubUID 生成出版物唯一标识。
func epubUID(book *domain.Book) string {
	id := book.BookURL
	if id == "" {
		id = fmt.Sprintf("%s-%s", book.Name, book.Author)
	}
	// 去除非法字符，保证 urn 形式合法。
	cleaned := strings.Map(func(r rune) rune {
		if r == ' ' || r == '/' || r == '\\' || r == ':' || r == '?' || r == '#' {
			return '-'
		}
		return r
	}, id)
	return "urn:legado-desktop:" + cleaned
}

// normalizeHTML 解析并重新渲染 HTML，输出规范的 XHTML 片段。
func normalizeHTML(raw string) string {
	if strings.TrimSpace(raw) == "" {
		return "<p></p>"
	}
	node, err := html.Parse(strings.NewReader(raw))
	if err != nil {
		// 解析失败时回退为原文，由阅读端容错处理。
		return raw
	}
	body := findBody(node)
	if body == nil {
		body = node
	}
	var buf bytes.Buffer
	if err := html.Render(&buf, body); err != nil {
		return raw
	}
	out := buf.String()
	out = strings.Replace(out, "<body>", "", 1)
	out = strings.Replace(out, "</body>", "", 1)
	return out
}

// findBody 找到 html 节点下的 body 节点。
func findBody(node *html.Node) *html.Node {
	var found *html.Node
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if found != nil {
			return
		}
		if n.Type == html.ElementNode && n.Data == "body" {
			found = n
			return
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(node)
	return found
}

// wrapXHTML 把正文片段包装为完整的 XHTML 文档。
func wrapXHTML(title, body string) string {
	var buf strings.Builder
	buf.WriteString(`<?xml version="1.0" encoding="utf-8"?>`)
	buf.WriteString("\n")
	buf.WriteString(`<!DOCTYPE html>`)
	buf.WriteString("\n")
	buf.WriteString(`<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh">`)
	buf.WriteString("\n<head><title>")
	buf.WriteString(escapeXML(title))
	buf.WriteString("</title></head>\n<body>\n")
	buf.WriteString(`<h1>`)
	buf.WriteString(escapeXML(title))
	buf.WriteString("</h1>\n")
	buf.WriteString(body)
	buf.WriteString("\n</body>\n</html>")
	return buf.String()
}

// escapeXML 转义 XML 特殊字符。
func escapeXML(s string) string {
	r := strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
	)
	return r.Replace(s)
}

// htmlToText 把 HTML 转为纯文本，用于 TXT 导出。
func htmlToText(raw string) string {
	if strings.TrimSpace(raw) == "" {
		return ""
	}
	node, err := html.Parse(strings.NewReader(raw))
	if err != nil {
		return stripTags(raw)
	}

	var buf strings.Builder
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		switch n.Type {
		case html.TextNode:
			buf.WriteString(n.Data)
		case html.ElementNode:
			// 块级元素前后补空行，保留段落结构。
			switch n.Data {
			case "p", "div", "br", "h1", "h2", "h3", "h4", "li", "tr":
				buf.WriteString("\n")
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
		if n.Type == html.ElementNode {
			switch n.Data {
			case "p", "div", "br", "h1", "h2", "h3", "h4", "li", "tr":
				buf.WriteString("\n")
			}
		}
	}
	walk(node)
	return tidyBlankLines(buf.String())
}

// stripTags 粗暴去除 HTML 标签，作为解析失败时的兜底。
func stripTags(s string) string {
	var buf strings.Builder
	inTag := false
	for _, r := range s {
		switch {
		case r == '<':
			inTag = true
		case r == '>':
			inTag = false
			buf.WriteRune('\n')
		case !inTag:
			buf.WriteRune(r)
		}
	}
	return tidyBlankLines(buf.String())
}

// tidyBlankLines 压缩连续空行，最多保留一个。
func tidyBlankLines(s string) string {
	lines := strings.Split(s, "\n")
	out := make([]string, 0, len(lines))
	blank := false
	for _, l := range lines {
		trimmed := strings.TrimSpace(l)
		if trimmed == "" {
			if blank {
				continue
			}
			blank = true
			out = append(out, "")
			continue
		}
		blank = false
		out = append(out, trimmed)
	}
	return strings.TrimSpace(strings.Join(out, "\n"))
}
