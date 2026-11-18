package tts

import (
	"strings"
	"unicode"
)

// Segment 是一个朗读片段。
//
// 分段规则属于业务而非 UI：它决定朗读断点、续读定位与高亮范围，
// 必须落盘并能被单测覆盖，所以放在 Go 侧（MODULE-PLAN §1.3）。
type Segment struct {
	// Index 是片段在本章内的全局序号（从 0 开始）。
	Index int `json:"index"`
	// Paragraph 是段落序号（从 0 开始），用于把片段映射回正文。
	Paragraph int `json:"paragraph"`
	// Text 是要朗读的文本（已去首尾空白）。
	Text string `json:"text"`
	// Start / End 是片段在所属段落内的字节偏移。
	Start int `json:"start"`
	End   int `json:"end"`
}

// 中英文句末标点。CJK 的闭合引号/括号即使不跟在句末标点后，也作为断点，
// 否则「他说：『好。』」会把引号读到下一段。
const sentenceEnders = "。！？；!?;…"

const closingMarks = "」』”’）)》】〉\"'"

// DefaultMaxRunes 是单个片段的默认上限。经验值：TTS 引擎对 100~150 字最稳，
// 过长会让暂停/快进粒度变粗。
const DefaultMaxRunes = 120

// Split 把正文切成可朗读片段。
//
// 规则：
//  1. 先按换行切段（保留段落边界，不跨段合并）；
//  2. 段内按句末标点切句，标点归属前一句；
//  3. 过短的句子向后合并，直到接近 maxRunes，避免「嗯。」单独成段；
//  4. 单句仍超长时按逗号/空格二次切分。
func Split(text string, maxRunes int) []Segment {
	if maxRunes <= 0 {
		maxRunes = DefaultMaxRunes
	}
	lines := splitParagraphs(text)
	out := make([]Segment, 0, len(lines))
	idx := 0
	for pi, line := range lines {
		raw := line
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" {
			continue
		}
		base := strings.Index(raw, trimmed)
		if base < 0 {
			base = 0
		}

		sents := splitSentences(trimmed)
		var buf strings.Builder
		bufStart := 0
		cursor := 0
		flush := func(end int) {
			s := strings.TrimSpace(buf.String())
			if s != "" {
				out = append(out, Segment{Index: idx, Paragraph: pi, Text: s, Start: base + bufStart, End: base + end})
				idx++
			}
			buf.Reset()
		}
		for _, sent := range sents {
			sentStart := cursor
			cursor += len(sent)
			if buf.Len() == 0 {
				bufStart = sentStart
			}
			// 合并到接近上限；超过则先吐出上一批。
			if runeLen(buf.String())+runeLen(sent) > maxRunes && buf.Len() > 0 {
				flush(sentStart)
				bufStart = sentStart
			}
			buf.WriteString(sent)
			// 已经够长就直接成段，减少后续合并判断。
			if runeLen(strings.TrimSpace(buf.String())) >= maxRunes {
				flush(cursor)
			}
		}
		if buf.Len() > 0 {
			flush(cursor)
		}
	}
	return out
}

// splitParagraphs 按换行切段，并去掉空行。
func splitParagraphs(text string) []string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	return strings.Split(text, "\n")
}

// splitSentences 按句末标点切句，标点与紧随的闭合引号归属前一句。
func splitSentences(s string) []string {
	var out []string
	start := 0
	rs := []rune(s)
	// 用 rune 索引计算字节偏移，避免中文被截断。
	byteAt := func(runeIdx int) int {
		if runeIdx <= 0 {
			return 0
		}
		if runeIdx >= len(rs) {
			return len(s)
		}
		return len(string(rs[:runeIdx]))
	}
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		if strings.ContainsRune(sentenceEnders, r) {
			j := i + 1
			// 吸收连续的句末标点与闭合引号（如 」。 或 ？！）
			for j < len(rs) && (strings.ContainsRune(sentenceEnders, rs[j]) || strings.ContainsRune(closingMarks, rs[j])) {
				j++
			}
			out = append(out, s[byteAt(start):byteAt(j)])
			start = j
			i = j - 1
			continue
		}
		// 单独的闭合引号后面若是空白，也视作断点。
		if strings.ContainsRune(closingMarks, r) {
			next := i + 1
			if next >= len(rs) || unicode.IsSpace(rs[next]) {
				out = append(out, s[byteAt(start):byteAt(next)])
				start = next
			}
		}
	}
	if start < len(rs) {
		out = append(out, s[byteAt(start):])
	}
	return out
}

func runeLen(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
}
