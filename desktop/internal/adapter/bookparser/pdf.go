package bookparser

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// PDFParser 处理 PDF 书籍。
//
// 设计取舍（与调研结论一致）：Legado 安卓端用 Android PdfRenderer 把每页渲成位图，
// 本质上是"图片格式"而非文本格式，正文没有文本层。
// 桌面端走 WebView，可以直接用 pdf.js 渲染——既能拿到真实文本层，
// 又有书签与页码，Go 侧再去解析反而多余，还会引入 cgo 或中文 CID 字体问题。
//
// 因此本解析器只负责：
//  1. 让 PDF 能进入书架并记住阅读位置；
//  2. 目录（大纲）由前端解析后通过 SyncOutline 回写到后端。
//
// 正文渲染完全交给前端，Content 返回空 HTML 作为显式信号。
type PDFParser struct{}

// NewPDFParser 创建 PDF 解析器。
func NewPDFParser() *PDFParser { return &PDFParser{} }

var _ port.LocalBookParser = (*PDFParser)(nil)

// Format 返回支持的格式。
func (p *PDFParser) Format() domain.BookFormat { return domain.BookFormatPDF }

// Parse 解析 PDF：仅读取基本信息并建立占位章节。
func (p *PDFParser) Parse(ctx context.Context, filePath string) (*port.ParsedBook, error) {
	info, err := os.Stat(filePath)
	if err != nil {
		return nil, fmt.Errorf("访问文件失败: %w", err)
	}
	if info.IsDir() {
		return nil, fmt.Errorf("%w: PDF 路径不能是目录", domain.ErrInvalidArgument)
	}

	// 校验 PDF 文件头，避免把损坏文件放进书架。
	if !looksLikePDF(filePath) {
		return nil, fmt.Errorf("%w: 不是有效的 PDF 文件", domain.ErrParseFailed)
	}

	name := strings.TrimSuffix(filepath.Base(filePath), filepath.Ext(filePath))
	return &port.ParsedBook{
		Chapters: []*domain.BookChapter{{
			Index:    0,
			Title:    "全文",
			Resource: "0", // 页码，前端同步大纲后会替换为真实条目
		}},
		Meta: port.BookMeta{Title: name},
	}, nil
}

// Content 返回空正文：PDF 由前端 pdf.js 渲染，后端不提供 HTML。
func (p *PDFParser) Content(ctx context.Context, filePath string, chapter *domain.BookChapter) (*port.ChapterContent, error) {
	return &port.ChapterContent{Title: chapter.Title}, nil
}

// looksLikePDF 读取文件头判断是否为 PDF（%PDF-）。
func looksLikePDF(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()

	head := make([]byte, 5)
	n, err := f.Read(head)
	if err != nil || n < 5 {
		return false
	}
	return string(head) == "%PDF-"
}
