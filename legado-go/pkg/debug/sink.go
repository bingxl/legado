package debug

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// —— 文本输出（终端） ——

// BodyMode 响应体在文本流里的呈现方式
type BodyMode int

const (
	// BodyNone 只输出摘要行，不输出正文（默认）
	BodyNone BodyMode = iota
	// BodyHead 输出前 BodyLimit 字节
	BodyHead
	// BodyFull 输出完整正文
	BodyFull
)

// ParseBodyMode 解析 -body 的取值：none/head/full
func ParseBodyMode(s string) (BodyMode, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "none", "off", "0":
		return BodyNone, nil
	case "head", "preview", "first":
		return BodyHead, nil
	case "full", "all", "1":
		return BodyFull, nil
	}
	return BodyNone, fmt.Errorf("未知的 -body 取值 %q（可选 none / head / full）", s)
}

// TextSink 面向终端的输出，逐行打印并可选着色
type TextSink struct {
	W io.Writer

	// Color 用 ANSI 着色：错误红、完成绿、响应体灰
	Color bool
	// BodyMode 响应体呈现方式
	BodyMode BodyMode
	// BodyLimit BodyHead 模式下的字节上限，<=0 时用 2048
	BodyLimit int
	// MsgLimit 单条普通日志的字符上限（rune 计），<=0 不限制。
	// 正文这类超长日志靠它兜底，-body 只作用于响应体记录。
	MsgLimit int
	// NoTime 关掉 [mm:ss.SSS] 前缀（对齐 Kotlin 的 showTime=false）
	NoTime bool
}

// Emit 实现 Sink
func (s *TextSink) Emit(e Entry) {
	if s.W == nil {
		return
	}
	msg := e.Msg
	switch {
	case !e.IsBody():
		if s.MsgLimit > 0 {
			msg = limitRunes(msg, s.MsgLimit)
		}
	case s.BodyMode == BodyNone:
		return
	case s.BodyMode == BodyHead:
		msg = headText(msg, s.bodyLimit())
	}

	var sb strings.Builder
	if !s.NoTime {
		sb.WriteString(FormatElapsed(e.Elapsed))
		sb.WriteByte(' ')
	}
	if s.Color {
		sb.WriteString(colorOf(e.State))
	}
	sb.WriteString(msg)
	if s.Color && colorOf(e.State) != "" {
		sb.WriteString("\x1b[0m")
	}
	sb.WriteByte('\n')
	_, _ = io.WriteString(s.W, sb.String())
}

func (s *TextSink) bodyLimit() int {
	if s.BodyLimit > 0 {
		return s.BodyLimit
	}
	return 2048
}

// colorOf 按 state 返回 ANSI 颜色前缀（空串表示默认色）
func colorOf(state int) string {
	switch {
	case state == StateError:
		return "\x1b[31m" // 红
	case state == StateDone:
		return "\x1b[32m" // 绿
	case state >= StateSearchBody && state <= StateContentBody:
		return "\x1b[90m" // 灰：响应体
	}
	return ""
}

// headText 截取前 limit 字节并标注总长度
func headText(s string, limit int) string {
	if len(s) <= limit {
		return s
	}
	// 不切坏多字节字符
	cut := limit
	for cut > 0 && !utf8Start(s[cut]) {
		cut--
	}
	return s[:cut] + fmt.Sprintf("\n…（已截断，共 %d 字节）", len(s))
}

// limitRunes 按字符数截断，避免把中文切坏
func limitRunes(s string, limit int) string {
	if limit <= 0 {
		return s
	}
	r := []rune(s)
	if len(r) <= limit {
		return s
	}
	return string(r[:limit]) + fmt.Sprintf("\n…（已截断，共 %d 字）", len(r))
}

func utf8Start(b byte) bool { return b&0xC0 != 0x80 }

// FormatElapsed 生成与客户端一致的 [mm:ss.SSS]；超过 1 小时补上小时段
func FormatElapsed(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	ms := int(d/time.Millisecond) % 1000
	sec := int(d/time.Second) % 60
	min := int(d/time.Minute) % 60
	if h := int(d / time.Hour); h > 0 {
		return fmt.Sprintf("[%d:%02d:%02d.%03d]", h, min, sec, ms)
	}
	return fmt.Sprintf("[%02d:%02d.%03d]", min, sec, ms)
}

// —— JSONL 输出（机器可读） ——

type jsonEntry struct {
	Time    int64  `json:"t"`                 // 相对起点毫秒
	At      string `json:"at"`                // [mm:ss.SSS]
	State   int    `json:"state"`             // 1 / -1 / 10 / 20 / 30 / 40 / 1000
	Name    string `json:"name"`              // state 的可读名
	BodyLen int    `json:"bodyLen,omitempty"` // 仅响应体记录：原始字节数
	Msg     string `json:"msg,omitempty"`
}

// JSONSink 每条记录输出一行 JSON，便于管道处理。
// 响应体按 BodyMode 决定是否内联，BodyLen 始终给出原始长度。
type JSONSink struct {
	W         io.Writer
	BodyMode  BodyMode
	BodyLimit int
	MsgLimit  int
}

// Emit 实现 Sink
func (s *JSONSink) Emit(e Entry) {
	if s.W == nil {
		return
	}
	je := jsonEntry{
		Time:  e.Elapsed.Milliseconds(),
		At:    FormatElapsed(e.Elapsed),
		State: e.State,
		Name:  StateName(e.State),
		Msg:   e.Msg,
	}
	switch {
	case e.IsBody():
		je.BodyLen = len(e.Msg)
		switch s.BodyMode {
		case BodyNone:
			je.Msg = ""
		case BodyHead:
			limit := s.BodyLimit
			if limit <= 0 {
				limit = 2048
			}
			je.Msg = headText(e.Msg, limit)
		}
	case s.MsgLimit > 0:
		je.Msg = limitRunes(je.Msg, s.MsgLimit)
	}
	b, err := json.Marshal(je)
	if err != nil {
		return
	}
	_, _ = s.W.Write(append(b, '\n'))
}

// —— 响应体落盘（对齐客户端"查看源码"） ——

// FileBodySink 把 state 10/20/30/40 的响应体各写成一个文件：search.html / info.html /
// toc.html / content.html；同一阶段翻页时依次写成 toc.2.html、toc.3.html。
type FileBodySink struct {
	Dir string

	mu  sync.Mutex
	seq map[int]int
}

// Emit 实现 Sink
func (s *FileBodySink) Emit(e Entry) {
	if !e.IsBody() || s.Dir == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.seq == nil {
		s.seq = map[int]int{}
	}
	s.seq[e.State]++
	name := fmt.Sprintf("%s.%s", StateName(e.State), extOf(e.Msg))
	if n := s.seq[e.State]; n > 1 {
		name = fmt.Sprintf("%s.%d.%s", StateName(e.State), n, extOf(e.Msg))
	}
	if err := os.MkdirAll(s.Dir, 0o755); err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(s.Dir, name), []byte(e.Msg), 0o644)
}

// extOf 粗判响应体类型：以 { 或 [ 开头当 JSON，其余当 HTML
func extOf(body string) string {
	t := strings.TrimSpace(body)
	if t != "" && (t[0] == '{' || t[0] == '[') {
		return "json"
	}
	return "html"
}

// —— 组合 ——

type multiSink []Sink

// Emit 实现 Sink
func (m multiSink) Emit(e Entry) {
	for _, s := range m {
		s.Emit(e)
	}
}

// Multi 把多个 Sink 合成一个，按顺序分发
func Multi(sinks ...Sink) Sink {
	live := make(multiSink, 0, len(sinks))
	for _, s := range sinks {
		if s != nil {
			live = append(live, s)
		}
	}
	return live
}
