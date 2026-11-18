package tts

import (
	"strings"
	"testing"
)

// 中文按句末标点切句，标点归属前一句。
func TestSplitBySentence(t *testing.T) {
	segs := Split("第一句。第二句！第三句？", 120)
	if len(segs) != 1 {
		// 三句合计 12 字，远小于 120，应当合并成一个片段。
		t.Fatalf("短句应合并成 1 段，实际 %d 段: %+v", len(segs), segs)
	}
	if segs[0].Text != "第一句。第二句！第三句？" {
		t.Fatalf("合并后的文本不对: %q", segs[0].Text)
	}
}

// 超过上限时要切分，且顺序与内容不能丢。
func TestSplitRespectsMaxRunes(t *testing.T) {
	text := "一二三四五。六七八九十。甲乙丙丁戊。"
	segs := Split(text, 6)
	if len(segs) < 2 {
		t.Fatalf("应当切分成多段，实际 %d 段", len(segs))
	}
	for _, s := range segs {
		if n := len([]rune(s.Text)); n > 12 {
			t.Errorf("片段 %d 过长: %d 字 %q", s.Index, n, s.Text)
		}
	}
	var joined strings.Builder
	for _, s := range segs {
		joined.WriteString(s.Text)
	}
	if joined.String() != text {
		t.Errorf("拼接后与原文不一致:\n got: %q\nwant: %q", joined.String(), text)
	}
}

// 段内偏移必须是**字符**偏移：UI 的 substring 按 UTF-16 码元算，
// 若按字节返回，一个中文字会被算成 3 个位置。
func TestSegmentOffsetsAreRunes(t *testing.T) {
	segs := Split("第一句。第二句。", 5)
	if len(segs) != 2 {
		t.Fatalf("期望 2 段，实际 %d: %+v", len(segs), segs)
	}
	if segs[0].Start != 0 || segs[0].End != 4 {
		t.Errorf("首段偏移 = [%d,%d)，期望 [0,4)", segs[0].Start, segs[0].End)
	}
	if segs[1].Start != 4 || segs[1].End != 8 {
		t.Errorf("次段偏移 = [%d,%d)，期望 [4,8)", segs[1].Start, segs[1].End)
	}

	// 用偏移回切原文必须正好等于片段文本，这是偏移正确性的直接判据。
	src := []rune("第一句。第二句。")
	for _, s := range segs {
		if got := string(src[s.Start:s.End]); got != s.Text {
			t.Errorf("片段 %d 按偏移回切 = %q，期望 %q", s.Index, got, s.Text)
		}
	}
}

// 多段落时 Paragraph 要递增，跨段不合并。
func TestSplitKeepsParagraphs(t *testing.T) {
	segs := Split("第一段内容。\n\n第二段内容。", 120)
	if len(segs) != 2 {
		t.Fatalf("期望 2 段（空行被跳过），实际 %d: %+v", len(segs), segs)
	}
	if segs[0].Paragraph != 0 || segs[1].Paragraph != 2 {
		t.Errorf("段落号 = %d,%d，期望 0,2（空行占一个下标）",
			segs[0].Paragraph, segs[1].Paragraph)
	}
}

// 闭合引号与连续标点不能被切到下一句。
func TestSplitAbsorbsClosingMarks(t *testing.T) {
	// maxRunes=8：两句分别 7 字和 5 字，都不到上限，不会触发二次切分，
	// 正好能单独验证「句末标点 + 闭合引号归属前一句」。
	segs := Split("他说：「好。」然后走了。", 8)
	if len(segs) != 2 {
		t.Fatalf("期望 2 段，实际 %d: %+v", len(segs), segs)
	}
	if segs[0].Text != "他说：「好。」" {
		t.Errorf("首段没有把引号一起带走: %q", segs[0].Text)
	}
	if segs[1].Text != "然后走了。" {
		t.Errorf("次段 = %q", segs[1].Text)
	}
}

func TestSplitEmptyAndBlank(t *testing.T) {
	if got := Split("", 10); len(got) != 0 {
		t.Errorf("空文本应返回空切片，实际 %+v", got)
	}
	if got := Split("  \n\n \t ", 10); len(got) != 0 {
		t.Errorf("纯空白应返回空切片，实际 %+v", got)
	}
}

// maxRunes<=0 时退到默认 120，不能因为负数把文本切成一字一段。
func TestSplitDefaultsMaxRunes(t *testing.T) {
	text := strings.Repeat("文", 200)
	segs := Split(text, 0)
	// 200 字 / 默认 120 → 120 + 80 两段；没有标点，只能硬切。
	if len(segs) != 2 {
		t.Fatalf("期望 2 段，实际 %d 段", len(segs))
	}
	segs = Split(text, -5)
	if len(segs) != 2 {
		t.Fatalf("负数应退回默认 120，实际 %d 段", len(segs))
	}
	if got := len([]rune(segs[0].Text)); got != DefaultMaxRunes {
		t.Errorf("首段 %d 字，期望 %d", got, DefaultMaxRunes)
	}
}

// 超长单句要按逗号二次切分，否则朗读要等整句读完才能暂停。
func TestSplitLongSentence(t *testing.T) {
	text := strings.Repeat("这是一个很长的分句，", 20) + "结束。"
	segs := Split(text, 20)
	if len(segs) < 3 {
		t.Fatalf("超长句应被切分成多段，实际 %d 段", len(segs))
	}
	for _, s := range segs {
		if n := len([]rune(s.Text)); n > 60 {
			t.Errorf("切分后仍然过长: %d 字", n)
		}
	}
}
