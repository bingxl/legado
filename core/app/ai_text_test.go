package app

import (
	"strings"
	"testing"
)

func TestAIPlainTextStripsMarkup(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"段落转行", `<p>第一段</p><p>第二段</p>`, "第一段\n第二段"},
		{"空段落被丢弃", "<p>一</p><p></p><p>二</p>", "一\n二"},
		{"行内标签", `他<b>很</b>生气`, "他很生气"},
		{"实体反转义", `a &amp; b &lt;c&gt; &quot;d&quot;`, `a & b <c> "d"`},
		{"去掉脚本", `<script>var x=1;</script>正文`, "正文"},
		{"去掉样式", `<style>.a{color:red}</style>正文`, "正文"},
		{"nbsp 折叠", "甲\u00a0\u00a0乙", "甲 乙"},
		{"全角空格折叠", "甲\u3000\u3000乙", "甲 乙"},
		{"首尾空白裁剪", "  \n 正文 \n ", "正文"},
		{"空输入", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := aiPlainText(c.in); got != c.want {
				t.Fatalf("aiPlainText(%q) = %q, 期望 %q", c.in, got, c.want)
			}
		})
	}
}

func TestAIPlainTextPreservesParagraphs(t *testing.T) {
	// 段落边界是切片的主要依据，不能被压成一行。
	got := aiPlainText("<p>一</p><p>二</p><p>三</p>")
	if strings.Count(got, "\n") != 2 {
		t.Fatalf("应保留 2 个换行，实际: %q", got)
	}
}

func TestEstimateTokens(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"", 0},
		{"中文", 2},       // 非 ASCII 按 1 字符 1 token
		{"abcd", 1},     // ASCII 4 字符 1 token
		{"abcdefgh", 2}, // 向上取整
		{"中文ab", 3},     // 2 + ceil(2/4)
		{"，。！", 3},      // 全角标点同样算 1
	}
	for _, c := range cases {
		if got := estimateTokens(c.in); got != c.want {
			t.Fatalf("estimateTokens(%q) = %d, 期望 %d", c.in, got, c.want)
		}
	}
}

func TestSplitChapterTextShort(t *testing.T) {
	chunks := splitChapterText("第一章", "只有一句话。", 3, 10)
	if len(chunks) != 1 {
		t.Fatalf("短文本应切出 1 片，实际 %d", len(chunks))
	}
	c := chunks[0]
	if c.ChapterIdx != 3 || c.Ordinal != 10 {
		t.Fatalf("章节/序号错误: %+v", c)
	}
	if c.Text != "只有一句话。" {
		t.Fatalf("文本 = %q", c.Text)
	}
	if c.Title != "第一章" {
		t.Fatalf("标题 = %q", c.Title)
	}
	if c.CharStart != 0 || c.CharEnd != 6 {
		t.Fatalf("偏移错误: %d..%d", c.CharStart, c.CharEnd)
	}
}

func TestSplitChapterTextEmpty(t *testing.T) {
	for _, in := range []string{"", "   ", "\n\n\n"} {
		if got := splitChapterText("t", in, 0, 0); len(got) != 0 {
			t.Fatalf("空白文本不应产生切片，实际 %d 片", len(got))
		}
	}
}

func TestSplitChapterTextCoversWholeText(t *testing.T) {
	// 构造 40 段、每段约 200 字的正文（约 8000 token），应切出多片。
	var paras []string
	for i := 0; i < 40; i++ {
		paras = append(paras, strings.Repeat("这是第若干段的内容说明。", 18))
	}
	text := strings.Join(paras, "\n")
	chunks := splitChapterText("长章", text, 0, 0)

	if len(chunks) < 5 {
		t.Fatalf("长文本应切出多片，实际 %d", len(chunks))
	}

	// 每片都不应显著超出预算（单行硬切除外，这里段落长度都远小于预算）。
	for i, c := range chunks {
		if c.TokenCount > aiChunkTargetTokens*2 {
			t.Fatalf("第 %d 片 token=%d 远超预算 %d", i, c.TokenCount, aiChunkTargetTokens)
		}
	}

	// 序号必须连续递增，否则入库后排序会错。
	for i, c := range chunks {
		if c.Ordinal != i {
			t.Fatalf("第 %d 片序号 = %d", i, c.Ordinal)
		}
		if c.ChapterIdx != 0 {
			t.Fatalf("章节号错误: %d", c.ChapterIdx)
		}
	}

	// 覆盖性：每一个非空白字符都应落在至少一片里。
	rs := []rune(text)
	covered := make([]bool, len(rs))
	for _, c := range chunks {
		for i := c.CharStart; i < c.CharEnd && i < len(covered); i++ {
			covered[i] = true
		}
	}
	for i, r := range rs {
		if r == '\n' || r == ' ' {
			continue
		}
		if !covered[i] {
			t.Fatalf("第 %d 个字符 %q 未被任何切片覆盖", i, r)
		}
	}

	// 文本内容必须与偏移一致（前端按偏移取片段时依赖这一点）。
	for _, c := range chunks {
		if got := string(rs[c.CharStart:c.CharEnd]); got != c.Text {
			t.Fatalf("偏移与文本不一致: 偏移取到 %q, 存的 %q", got, c.Text)
		}
	}
}

func TestSplitChapterTextHasOverlap(t *testing.T) {
	// 相邻片必须有重叠，否则跨段语义会被切断。
	var paras []string
	for i := 0; i < 40; i++ {
		paras = append(paras, strings.Repeat("重叠测试段落内容。", 20))
	}
	chunks := splitChapterText("章", strings.Join(paras, "\n"), 0, 0)
	if len(chunks) < 2 {
		t.Fatalf("样本不足以验证重叠，实际 %d 片", len(chunks))
	}
	for i := 1; i < len(chunks); i++ {
		if chunks[i].CharStart >= chunks[i-1].CharEnd {
			t.Fatalf("第 %d 片与前一片没有重叠: %d >= %d",
				i, chunks[i].CharStart, chunks[i-1].CharEnd)
		}
	}
}

func TestSplitChapterTextHardSplitsLongLine(t *testing.T) {
	// 一整章没有分段：必须硬切，否则单片会远超上下文预算。
	text := strings.Repeat("无分段的超长正文", 500) // 约 4000 token
	chunks := splitChapterText("长行", text, 0, 0)
	if len(chunks) < 2 {
		t.Fatalf("超长单行应被硬切，实际 %d 片", len(chunks))
	}
	for i, c := range chunks {
		if c.TokenCount > aiChunkTargetTokens {
			t.Fatalf("第 %d 片 token=%d 超过预算 %d", i, c.TokenCount, aiChunkTargetTokens)
		}
	}
	// 硬切也不能丢字。
	var sb strings.Builder
	for _, c := range chunks {
		sb.WriteString(c.Text)
	}
	if sb.Len() < len(text) {
		t.Fatalf("硬切后总长度 %d < 原文 %d", sb.Len(), len(text))
	}
}

func TestSplitChapterTextRuneOffsets(t *testing.T) {
	// 非 BMP 字符（emoji）在 JS 里占 2 个 UTF-16 单元，
	// 用 rune 偏移才与 Go/前端 Array.from 的口径一致。
	text := strings.Repeat("😀", 50) + "\n" + strings.Repeat("文", 50)
	chunks := splitChapterText("emoji", text, 0, 0)
	if len(chunks) == 0 {
		t.Fatal("应有切片")
	}
	if chunks[0].CharStart != 0 {
		t.Fatalf("首片起点 = %d", chunks[0].CharStart)
	}
	// 首片应覆盖 50 个 emoji + 换行 + 部分正文，字符数与 rune 计数一致。
	if got := runeCount(chunks[0].Text); got != chunks[0].CharEnd-chunks[0].CharStart {
		t.Fatalf("rune 长度不一致: %d vs %d", got, chunks[0].CharEnd-chunks[0].CharStart)
	}
}
