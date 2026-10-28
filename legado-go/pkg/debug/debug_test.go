package debug_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/legado/legado-go/pkg/debug"
)

func TestFormatElapsed(t *testing.T) {
	cases := []struct {
		d    time.Duration
		want string
	}{
		{0, "[00:00.000]"},
		{5 * time.Millisecond, "[00:00.005]"},
		{1234 * time.Millisecond, "[00:01.234]"},
		{61*time.Second + 7*time.Millisecond, "[01:01.007]"},
		{time.Hour + 2*time.Minute + 3*time.Second + 4*time.Millisecond, "[1:02:03.004]"},
		{-time.Second, "[00:00.000]"},
	}
	for _, c := range cases {
		if got := debug.FormatElapsed(c.d); got != c.want {
			t.Errorf("FormatElapsed(%v) = %q，期望 %q", c.d, got, c.want)
		}
	}
}

func TestStateName(t *testing.T) {
	cases := map[int]string{
		debug.StateLog:         "log",
		debug.StateError:       "error",
		debug.StateSearchBody:  "list",
		debug.StateInfoBody:    "info",
		debug.StateTocBody:     "toc",
		debug.StateContentBody: "content",
		debug.StateDone:        "done",
		12345:                  "log",
	}
	for state, want := range cases {
		if got := debug.StateName(state); got != want {
			t.Errorf("StateName(%d) = %q，期望 %q", state, got, want)
		}
	}
}

func TestDisabledByDefault(t *testing.T) {
	debug.SetSink(nil)
	if debug.Enabled() {
		t.Fatal("SetSink(nil) 后不应处于启用状态")
	}
	// 未启用时打点应完全无副作用（不 panic、不写入）
	var buf bytes.Buffer
	debug.Log("不应出现")
	debug.Pair("获取书名", "x")
	debug.Body(debug.StateTocBody, "body")
	if buf.Len() != 0 {
		t.Errorf("未启用时不应有输出，实际 %q", buf.String())
	}
}

func TestTextSinkStates(t *testing.T) {
	var buf bytes.Buffer
	debug.SetSink(&debug.TextSink{W: &buf, BodyMode: debug.BodyNone})
	defer debug.SetSink(nil)

	debug.Log("普通")
	debug.Error("出错")
	debug.Done("完成")
	debug.Body(debug.StateTocBody, "<html>目录</html>")

	got := buf.String()
	for _, want := range []string{"普通", "出错", "完成"} {
		if !strings.Contains(got, want) {
			t.Errorf("输出缺少 %q；实际:\n%s", want, got)
		}
	}
	// BodyNone：响应体记录整行都不输出
	if strings.Contains(got, "<html>目录</html>") {
		t.Errorf("BodyNone 不应输出响应体；实际:\n%s", got)
	}
	// 每行都带 [mm:ss.SSS] 前缀
	for line := range strings.SplitSeq(strings.TrimSpace(got), "\n") {
		if !strings.HasPrefix(line, "[") {
			t.Errorf("缺少时间戳前缀: %q", line)
		}
	}
}

func TestTextSinkBodyModes(t *testing.T) {
	body := strings.Repeat("a", 100)

	t.Run("head 截断并标注总长度", func(t *testing.T) {
		var buf bytes.Buffer
		debug.SetSink(&debug.TextSink{W: &buf, BodyMode: debug.BodyHead, BodyLimit: 10})
		defer debug.SetSink(nil)
		debug.Body(debug.StateContentBody, body)

		got := buf.String()
		if !strings.Contains(got, strings.Repeat("a", 10)) {
			t.Errorf("应保留前 10 字节；实际 %q", got)
		}
		if !strings.Contains(got, "已截断，共 100 字节") {
			t.Errorf("应标注总长度；实际 %q", got)
		}
	})

	t.Run("full 原样输出", func(t *testing.T) {
		var buf bytes.Buffer
		debug.SetSink(&debug.TextSink{W: &buf, BodyMode: debug.BodyFull})
		defer debug.SetSink(nil)
		debug.Body(debug.StateContentBody, body)

		if !strings.Contains(buf.String(), body) {
			t.Error("BodyFull 应输出完整响应体")
		}
	})

	t.Run("短响应体不截断", func(t *testing.T) {
		var buf bytes.Buffer
		debug.SetSink(&debug.TextSink{W: &buf, BodyMode: debug.BodyHead, BodyLimit: 1024})
		defer debug.SetSink(nil)
		debug.Body(debug.StateInfoBody, "短")
		if strings.Contains(buf.String(), "已截断") {
			t.Error("未超限时不应出现截断标注")
		}
	})
}

func TestTextSinkColor(t *testing.T) {
	var buf bytes.Buffer
	debug.SetSink(&debug.TextSink{W: &buf, Color: true, BodyMode: debug.BodyNone})
	defer debug.SetSink(nil)

	debug.Error("红")
	debug.Done("绿")
	debug.Log("默认")

	got := buf.String()
	if !strings.Contains(got, "\x1b[31m红") {
		t.Errorf("错误应为红色；实际 %q", got)
	}
	if !strings.Contains(got, "\x1b[32m绿") {
		t.Errorf("完成应为绿色；实际 %q", got)
	}
	if strings.Contains(got, "\x1b[31m默认") {
		t.Errorf("普通日志不应着色；实际 %q", got)
	}
}

func TestMsgLimitKeepsRunes(t *testing.T) {
	var buf bytes.Buffer
	debug.SetSink(&debug.TextSink{W: &buf, BodyMode: debug.BodyNone, MsgLimit: 3})
	defer debug.SetSink(nil)

	debug.Log("一二三四五")
	got := buf.String()
	if !strings.Contains(got, "一二三") {
		t.Errorf("应保留前 3 个字；实际 %q", got)
	}
	if !strings.Contains(got, "已截断，共 5 字") {
		t.Errorf("应标注总字数；实际 %q", got)
	}
	if strings.Contains(got, "四五") {
		t.Errorf("超出部分不应出现；实际 %q", got)
	}
}

func TestJSONSink(t *testing.T) {
	var buf bytes.Buffer
	debug.SetSink(&debug.JSONSink{W: &buf, BodyMode: debug.BodyNone})
	defer debug.SetSink(nil)

	debug.Log("普通")
	debug.Body(debug.StateTocBody, "<html>目录</html>")

	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("应输出 2 行，实际 %d 行:\n%s", len(lines), buf.String())
	}

	var first, second map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatalf("首行不是合法 JSON: %v", err)
	}
	if first["msg"] != "普通" || first["state"].(float64) != 1 || first["name"] != "log" {
		t.Errorf("首行字段错误: %v", first)
	}

	if err := json.Unmarshal([]byte(lines[1]), &second); err != nil {
		t.Fatalf("次行不是合法 JSON: %v", err)
	}
	if second["state"].(float64) != 30 || second["name"] != "toc" {
		t.Errorf("响应体行字段错误: %v", second)
	}
	if second["bodyLen"].(float64) != float64(len("<html>目录</html>")) {
		t.Errorf("bodyLen 错误: %v", second["bodyLen"])
	}
	// BodyNone 时正文不内联，避免 9KB HTML 塞进一行
	if _, ok := second["msg"]; ok {
		t.Errorf("BodyNone 不应内联 msg；实际 %v", second["msg"])
	}
}

func TestFileBodySink(t *testing.T) {
	dir := t.TempDir()
	debug.SetSink(&debug.FileBodySink{Dir: dir})
	defer debug.SetSink(nil)

	debug.Body(debug.StateSearchBody, `{"a":1}`)
	debug.Body(debug.StateTocBody, "<html>第一页</html>")
	debug.Body(debug.StateTocBody, "<html>第二页</html>")
	debug.Log("普通日志不该落盘")

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	slices.Sort(names)

	want := []string{"list.json", "toc.2.html", "toc.html"}
	if !slices.Equal(names, want) {
		t.Fatalf("落盘文件 = %v，期望 %v", names, want)
	}
	// 内容必须是原始响应体
	b, err := os.ReadFile(filepath.Join(dir, "toc.2.html"))
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "<html>第二页</html>" {
		t.Errorf("第二页内容错误: %q", b)
	}
	// JSON 响应体按扩展名区分
	if b, _ := os.ReadFile(filepath.Join(dir, "list.json")); string(b) != `{"a":1}` {
		t.Errorf("JSON 响应体内容错误: %q", b)
	}
}

// TestPairIsAtomic 并发打点时，┌ 与 └ 必须成对相邻，不能与其他 goroutine 的记录交错。
// 下载是多协程抓取，这条性质决定了日志是否可读。
func TestPairIsAtomic(t *testing.T) {
	var buf bytes.Buffer
	debug.SetSink(&debug.TextSink{W: &buf, BodyMode: debug.BodyNone})
	defer debug.SetSink(nil)

	const n = 64
	var wg sync.WaitGroup
	for range n {
		wg.Go(func() {
			debug.Pair("获取书名", "某本书")
		})
	}
	wg.Wait()

	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 2*n {
		t.Fatalf("应有 %d 行，实际 %d 行:\n%s", 2*n, len(lines), buf.String())
	}
	for i := 0; i < len(lines); i += 2 {
		if !strings.Contains(lines[i], "┌获取书名") || !strings.Contains(lines[i+1], "└某本书") {
			t.Fatalf("第 %d 组不配对:\n  %q\n  %q", i/2, lines[i], lines[i+1])
		}
	}
}

func TestMultiSink(t *testing.T) {
	var text, js bytes.Buffer
	debug.SetSink(debug.Multi(
		&debug.TextSink{W: &text, BodyMode: debug.BodyNone},
		&debug.JSONSink{W: &js, BodyMode: debug.BodyNone},
	))
	defer debug.SetSink(nil)

	debug.Log("双写")
	if !strings.Contains(text.String(), "双写") {
		t.Error("文本 Sink 未收到日志")
	}
	if !strings.Contains(js.String(), `"msg":"双写"`) {
		t.Errorf("JSON Sink 未收到日志: %q", js.String())
	}
}

func TestParseBodyMode(t *testing.T) {
	cases := map[string]debug.BodyMode{
		"":       debug.BodyNone,
		"none":   debug.BodyNone,
		"HEAD":   debug.BodyHead,
		" full ": debug.BodyFull,
		"all":    debug.BodyFull,
	}
	for in, want := range cases {
		got, err := debug.ParseBodyMode(in)
		if err != nil {
			t.Errorf("ParseBodyMode(%q) 报错: %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("ParseBodyMode(%q) = %v，期望 %v", in, got, want)
		}
	}
	if _, err := debug.ParseBodyMode("everything"); err == nil {
		t.Error("非法取值应报错")
	}
}
