package app

import (
	stdhtml "html"
	"regexp"
	"strings"
	"unicode/utf8"
)

// 章节正文在缓存里是 HTML（书源原文或本地书 textToHTML 的产物），
// 喂给模型前必须转成纯文本：标签会浪费 token，且容易让模型把 <p> 当成内容复述。

var (
	reAIScriptStyle = regexp.MustCompile(`(?is)<(script|style)\b[^>]*>.*?</(script|style)>`)
	// 块级标签替换为换行：段落边界是后续切片的重要参考点，
	// 若直接删掉会让整章黏成一行，切片只能按字数硬切。
	reAIBlockTag = regexp.MustCompile(`(?i)</?(p|div|br|h[1-6]|li|ul|ol|tr|td|th|table|section|article|blockquote|pre|hr)\b[^>]*>`)
	reAITag      = regexp.MustCompile(`(?s)<[^>]*>`)
	// 用双引号而非反引号：反引号里的 `\u00a0` 会原样传给 regexp，而 Go 的
	// regexp 不认 `\u` 转义（只认 `\x{...}`），启动时直接 panic。
	reAISpace = regexp.MustCompile("[ \t\u00a0\u3000]+")
)

// aiPlainText 把章节 HTML 转成适合喂给模型的纯文本。
//
// 每段一行、丢弃空行：空行对模型没有信息价值，却会占用 token 预算。
func aiPlainText(raw string) string {
	if raw == "" {
		return ""
	}
	s := reAIScriptStyle.ReplaceAllString(raw, "")
	s = reAIBlockTag.ReplaceAllString(s, "\n")
	s = reAITag.ReplaceAllString(s, "")
	// 实体反转义放在去标签之后：正文里常有 &lt; 这类转义，
	// 提前反转义会被后面的正则误判成标签。
	s = stdhtml.UnescapeString(s)

	lines := strings.Split(s, "\n")
	var b strings.Builder
	b.Grow(len(s))
	for _, line := range lines {
		line = reAISpace.ReplaceAllString(line, " ")
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		b.WriteString(line)
		b.WriteString("\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

// ── token 估算 ──────────────────────────────────────────────

// estimateTokens 粗略估算文本的 token 数。
//
// 口径刻意保守：中文按「1 个字符 = 1 token」，ASCII 按 4 字符 1 token。
// 真实中文 tokenizer 大约 1.5~2 字/token，所以这个估计偏高——
// 宁可少塞一点，也不要因为低估而撞上下文上限导致整次调用失败。
func estimateTokens(s string) int {
	var ascii, wide int
	for _, r := range s {
		if r < 128 {
			ascii++
		} else {
			wide++
		}
	}
	return wide + (ascii+3)/4
}

// ── 切片 ────────────────────────────────────────────────────

const (
	// aiChunkTargetTokens 是单片的 token 预算。
	// 太小会让召回碎片化、向量数量暴涨；太大则一片里混进多个主题，拉低相似度精度。
	aiChunkTargetTokens = 700
	// aiChunkOverlapTokens 是相邻片的重叠量。
	// 不重叠会让「跨段的一句话」被切断，问答时两边都召回不到完整语义。
	aiChunkOverlapTokens = 80
)

// aiTextChunk 是切片结果（尚未入库）。
type aiTextChunk struct {
	ChapterIdx int
	Ordinal    int // 书内全局序号
	// CharStart/CharEnd 是**rune 偏移**，不是字节偏移。
	// 前端取片段时要用 Array.from(text).slice(...) 而非 String.slice，
	// 否则遇到非 BMP 字符（emoji）会错位。
	CharStart  int
	CharEnd    int
	Title      string
	Text       string
	TokenCount int
}

// aiLine 把文本按行切成可累积的单元，并记录 rune 偏移。
type aiLine struct {
	start  int
	end    int
	tokens int
}

// splitChapterText 把一个章节的纯文本切成若干片。
//
// 策略：按行（即段落）累积到 token 预算，超出即切一片；下一片回退若干 token
// 与前一片重叠，避免语义被切断。单行超预算时按字数硬切——网络小说里
// 「一整章没有分段」并不罕见，不处理会让单片远超预算。
func splitChapterText(title, text string, chapterIdx, startOrdinal int) []aiTextChunk {
	if strings.TrimSpace(text) == "" {
		return nil
	}
	rs := []rune(text)
	lines := splitLinesWithOffsets(rs)
	if len(lines) == 0 {
		return nil
	}

	out := make([]aiTextChunk, 0, len(lines)/4+1)
	ordinal := startOrdinal

	for i := 0; i < len(lines); {
		start := lines[i].start
		tokens := 0
		j := i
		for j < len(lines) {
			// 至少容纳一行，否则单行超预算时会死循环。
			if j > i && tokens+lines[j].tokens > aiChunkTargetTokens {
				break
			}
			tokens += lines[j].tokens
			j++
			if tokens >= aiChunkTargetTokens {
				break
			}
		}
		end := lines[j-1].end

		out = append(out, aiTextChunk{
			ChapterIdx: chapterIdx,
			Ordinal:    ordinal,
			CharStart:  start,
			CharEnd:    end,
			Title:      title,
			Text:       string(rs[start:end]),
			TokenCount: tokens,
		})
		ordinal++

		if j >= len(lines) {
			break
		}

		// 回退 overlap：从已包含的最后一行往回累计。
		k := j - 1
		back := 0
		for k > i && back < aiChunkOverlapTokens {
			back += lines[k].tokens
			k--
		}
		next := k + 1
		// 必须保证前进：overlap 覆盖了整段时，若只让 k 回退就会停在原地。
		if next <= i {
			next = i + 1
		}
		i = next
	}
	return out
}

// splitLinesWithOffsets 按换行拆行并记录 rune 区间；超长行按预算硬切。
func splitLinesWithOffsets(rs []rune) []aiLine {
	var lines []aiLine
	pos := 0
	lineStart := 0

	flush := func(end int) {
		if end <= lineStart {
			return
		}
		seg := string(rs[lineStart:end])
		if estimateTokens(seg) <= aiChunkTargetTokens {
			lines = append(lines, aiLine{
				start: lineStart, end: end, tokens: estimateTokens(seg),
			})
			return
		}
		// 硬切：按预算长度分段，保证单片不超太多。
		for s := lineStart; s < end; s += aiChunkTargetTokens {
			e := s + aiChunkTargetTokens
			if e > end {
				e = end
			}
			lines = append(lines, aiLine{
				start: s, end: e, tokens: estimateTokens(string(rs[s:e])),
			})
		}
	}

	for pos = 0; pos < len(rs); pos++ {
		if rs[pos] == '\n' {
			flush(pos)
			lineStart = pos + 1
		}
	}
	flush(len(rs))
	return lines
}

// runeCount 返回字符数，供测试与日志使用。
func runeCount(s string) int { return utf8.RuneCountInString(s) }
