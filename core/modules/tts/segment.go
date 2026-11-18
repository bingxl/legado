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
	// Start / End 是片段在所属段落内的**字符（rune）偏移**，左闭右开。
	//
	// 不用字节偏移：UI 侧（Dart 的 substring / 高亮 Range）按 UTF-16 码元计数，
	// 一个中文字在 UTF-8 里是 3 字节、在 UTF-16 里是 1 个码元。按字节返回会让
	// 高亮范围越界到 3 倍位置。BMP 内的中文下 rune 数 == UTF-16 长度，
	// 只有超出行星平面的 emoji 会差一点，可接受。
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
		// 偏移一律按字符计（见 Segment.Start 的注释）：先把字节下标换成字符数。
		base = runeLen(raw[:base])

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
		// 单句就超过上限时必须二次切开，否则「一整段没有句号」的网络小说
		// 会变成一个几千字的片段，朗读既不能暂停也不能快进。
		// 先切再进循环：pieces 拼起来仍等于原句，偏移量不受影响。
		var pieces []string
		for _, sent := range sents {
			pieces = append(pieces, splitLong(sent, maxRunes)...)
		}
		for _, sent := range pieces {
			sentStart := cursor
			cursor += runeLen(sent)
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

// softBreaks 是二次切分时的候选断点，优先级从高到低（只影响切点位置）。
const softBreaks = "，、：；,;: \u3000\t"

// splitLong 把超过 maxRunes 的句子按软断点切成多段。
//
// 切点尽量靠近上限，但**必须是**软断点：在词中间断开会让朗读引擎
// 把「的」「了」这类单字读成独立片段，听感很碎。找不到断点时
// （比如整句没有标点）才硬切。
func splitLong(s string, maxRunes int) []string {
	if maxRunes <= 0 || runeLen(s) <= maxRunes {
		return []string{s}
	}
	rs := []rune(s)
	out := make([]string, 0, len(rs)/maxRunes+1)
	for len(rs) > 0 {
		if len(rs) <= maxRunes {
			out = append(out, string(rs))
			break
		}
		cut := 0
		// 从上限往回找最近的软断点；至少切 1 个字，避免零长度循环。
		for i := maxRunes; i > 0; i-- {
			if strings.ContainsRune(softBreaks, rs[i-1]) {
				cut = i
				break
			}
		}
		if cut <= 0 {
			cut = maxRunes
		}
		out = append(out, string(rs[:cut]))
		rs = rs[cut:]
	}
	return out
}
