package bookparser

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/legado/desktop/internal/domain"
)

// writeTemp 写入临时文件并返回路径。
func writeTemp(t *testing.T, name, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("写入临时文件失败: %v", err)
	}
	return path
}

func TestTXTParser_RecognizesChineseChapters(t *testing.T) {
	// 覆盖最常见的中文网文标题写法，验证默认目录规则可用。
	text := strings.Join([]string{
		"测试书名",
		"作者：某人",
		"",
		"第一章 初入江湖",
		"这里是第一章的正文内容。",
		"",
		"第二章 小有名气",
		"这里是第二章的正文内容。",
		"",
		"第十章 名扬天下",
		"这里是第十章的正文。",
	}, "\n")
	path := writeTemp(t, "book.txt", text)

	p := NewTXTParser()
	parsed, err := p.Parse(context.Background(), path)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(parsed.Chapters) != 3 {
		t.Fatalf("期望识别 3 章，实际 %d: %+v", len(parsed.Chapters), chapterTitles(parsed.Chapters))
	}
	if !strings.Contains(parsed.Chapters[0].Title, "第一章") {
		t.Fatalf("首章标题不符: %q", parsed.Chapters[0].Title)
	}
	if parsed.Meta.Title != "测试书名" {
		t.Fatalf("书名推断失败: %q", parsed.Meta.Title)
	}

	// 正文应能按偏移取出且不包含相邻章节内容。
	content, err := p.Content(context.Background(), path, parsed.Chapters[1])
	if err != nil {
		t.Fatalf("取正文失败: %v", err)
	}
	if !strings.Contains(content.HTML, "第二章的正文") {
		t.Fatalf("第二章正文不符: %s", content.HTML)
	}
	if strings.Contains(content.HTML, "第一章的正文") {
		t.Fatalf("章节内容越界，混入了上一章: %s", content.HTML)
	}
}

func TestTXTParser_NoTocFallsBackToLengthSplit(t *testing.T) {
	// 构造一段不含任何目录特征的长文本。
	text := strings.Repeat("这是一段没有目录标记的正文内容。", 2000)
	path := writeTemp(t, "notoc.txt", text)

	p := NewTXTParser()
	p.MaxChapterChars = 1000
	parsed, err := p.Parse(context.Background(), path)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(parsed.Chapters) < 2 {
		t.Fatalf("无目录时应按字数强制分章，实际 %d 章", len(parsed.Chapters))
	}
}

func TestTXTParser_DecodesGBK(t *testing.T) {
	// "第一章" 的 GBK 编码，用于验证编码检测生效。
	gbk := []byte{0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x0A, 0xD5, 0xFD, 0xCE, 0xC4}
	dir := t.TempDir()
	path := filepath.Join(dir, "gbk.txt")
	if err := os.WriteFile(path, gbk, 0o644); err != nil {
		t.Fatalf("写入失败: %v", err)
	}

	p := NewTXTParser()
	parsed, err := p.Parse(context.Background(), path)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(parsed.Chapters) == 0 {
		t.Fatal("未识别到章节")
	}
	if !strings.Contains(parsed.Chapters[0].Title, "章") {
		t.Fatalf("GBK 解码失败，标题为: %q", parsed.Chapters[0].Title)
	}
}

func TestComicParser_NaturalSortAndDirScan(t *testing.T) {
	dir := t.TempDir()
	// 故意用会触发字典序错乱的文件名：2 应排在 10 之前。
	for _, name := range []string{"page1.png", "page2.png", "page10.png", "notes.txt"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatalf("写入失败: %v", err)
		}
	}

	p := NewComicParser(t.TempDir(), "/local/comic")
	parsed, err := p.Parse(context.Background(), dir)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(parsed.Chapters) != 1 {
		t.Fatalf("期望 1 话，实际 %d", len(parsed.Chapters))
	}

	content, err := p.Content(context.Background(), dir, parsed.Chapters[0])
	if err != nil {
		t.Fatalf("取内容失败: %v", err)
	}
	if len(content.Images) != 3 {
		t.Fatalf("期望 3 张图片（txt 应被过滤），实际 %d", len(content.Images))
	}
	// 自然序检查：page2 必须在 page10 之前。
	joined := strings.Join(content.Images, "|")
	if strings.Index(joined, "page2") > strings.Index(joined, "page10") {
		t.Fatalf("自然排序失效: %s", joined)
	}
	for _, u := range content.Images {
		if !strings.HasPrefix(u, "/local/comic/") {
			t.Fatalf("图片 URL 前缀不符: %s", u)
		}
	}
}

func TestPDFParser_RejectsNonPDF(t *testing.T) {
	path := writeTemp(t, "fake.pdf", "not a pdf")
	p := NewPDFParser()
	if _, err := p.Parse(context.Background(), path); err == nil {
		t.Fatal("非 PDF 文件应当报错")
	}
}

// chapterTitles 提取章节标题，便于错误输出。
func chapterTitles(in []*domain.BookChapter) []string {
	out := make([]string, 0, len(in))
	for _, c := range in {
		out = append(out, c.Title)
	}
	return out
}

// TestTXTParser_RealisticNovel 用接近真实网文的样本验证识别率与性能：
// 每章 2000+ 字、标题带序号、正文里故意出现「第X章」字样作为干扰。
func TestTXTParser_RealisticNovel(t *testing.T) {
	const chapters = 80
	body := strings.Repeat("他想起刚才那番话，心里久久不能平静。剑光一闪，胜负已分。", 60) // 约 1800 字
	var sb strings.Builder
	sb.WriteString("剑影长歌\n作者：某某\n\n")
	for i := 1; i <= chapters; i++ {
		sb.WriteString("第")
		sb.WriteString(numberToChinese(i))
		sb.WriteString("章 风起云涌\n")
		sb.WriteString(body)
		sb.WriteString("\n\n")
		// 干扰行：正文里提到别的章节，不应被当成目录
		sb.WriteString("他翻回第三章，想再看一遍那段对话。\n")
		sb.WriteString(body)
		sb.WriteString("\n\n")
	}
	path := writeTemp(t, "novel.txt", sb.String())

	start := time.Now()
	parsed, err := NewTXTParser().Parse(context.Background(), path)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(parsed.Chapters) != chapters {
		t.Fatalf("期望 %d 章，实际 %d（首末标题 %q / %q）",
			chapters, len(parsed.Chapters),
			parsed.Chapters[0].Title, parsed.Chapters[len(parsed.Chapters)-1].Title)
	}
	if !strings.Contains(parsed.Chapters[0].Title, "第一章") {
		t.Fatalf("首章标题不符: %q", parsed.Chapters[0].Title)
	}
	if elapsed > 5*time.Second {
		t.Fatalf("解析耗时过长: %s（文件名 %d 字节）", elapsed, sb.Len())
	}
	t.Logf("解析 %d 章、%d 字节，耗时 %s", len(parsed.Chapters), sb.Len(), elapsed)
}

// numberToChinese 把 1..999 转成中文数字，用于生成章节标题。
func numberToChinese(n int) string {
	digits := []string{"零", "一", "二", "三", "四", "五", "六", "七", "八", "九"}
	if n < 10 {
		return digits[n]
	}
	if n < 20 {
		return "十" + strings.TrimSuffix(digits[n%10], "零")
	}
	if n < 100 {
		s := digits[n/10] + "十"
		if n%10 != 0 {
			s += digits[n%10]
		}
		return s
	}
	s := digits[n/100] + "百"
	rest := n % 100
	if rest == 0 {
		return s
	}
	if rest < 10 {
		return s + "零" + digits[rest]
	}
	return s + numberToChinese(rest)
}
