package aihttp

import (
	"errors"
	"strings"
	"testing"
)

func TestScanSSECollectsDataLines(t *testing.T) {
	// 真实流里除了 data 还有 event/id/注释行，都必须被忽略。
	input := strings.Join([]string{
		": keep-alive comment",
		"event: message",
		"id: 1",
		`data: {"n":1}`,
		"",
		`data: {"n":2}`,
		"",
		"data: [DONE]",
		"",
	}, "\n")

	var got []string
	err := scanSSE(strings.NewReader(input), func(d string) error {
		got = append(got, d)
		return nil
	})
	if err != nil {
		t.Fatalf("scanSSE 返回错误: %v", err)
	}
	want := []string{`{"n":1}`, `{"n":2}`}
	if len(got) != len(want) {
		t.Fatalf("收到 %d 条，期望 %d 条: %v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("第 %d 条 = %q, 期望 %q", i, got[i], want[i])
		}
	}
}

func TestScanSSEStopsAtDone(t *testing.T) {
	// [DONE] 之后即便还有数据也不应再回调。
	input := "data: a\n\ndata: [DONE]\n\ndata: b\n\n"
	var got []string
	if err := scanSSE(strings.NewReader(input), func(d string) error {
		got = append(got, d)
		return nil
	}); err != nil {
		t.Fatalf("scanSSE 返回错误: %v", err)
	}
	if len(got) != 1 || got[0] != "a" {
		t.Fatalf("期望只收到 a，实际 %v", got)
	}
}

func TestScanSSEHandlesCRLF(t *testing.T) {
	input := "data: x\r\n\r\ndata: y\r\n\r\n"
	var got []string
	if err := scanSSE(strings.NewReader(input), func(d string) error {
		got = append(got, d)
		return nil
	}); err != nil {
		t.Fatalf("scanSSE 返回错误: %v", err)
	}
	// 若未剥掉 \r，这里会拿到 "y\r" 之类，进而 JSON 解析失败。
	if len(got) != 2 || got[0] != "x" || got[1] != "y" {
		t.Fatalf("CRLF 处理错误: %v", got)
	}
}

func TestScanSSELongLineNotTruncated(t *testing.T) {
	// 默认 64KB 行上限会让长分片直接报 ErrTooLong，表现为回答莫名中断。
	big := strings.Repeat("x", 200*1024)
	input := "data: " + big + "\n\ndata: [DONE]\n\n"
	var got string
	if err := scanSSE(strings.NewReader(input), func(d string) error {
		got = d
		return nil
	}); err != nil {
		t.Fatalf("超长行应能读取，实际报错: %v", err)
	}
	if len(got) != len(big) {
		t.Fatalf("长行被截断: 收到 %d, 期望 %d", len(got), len(big))
	}
}

func TestScanSSEPropagatesCallbackError(t *testing.T) {
	sentinel := errors.New("stop")
	input := "data: a\n\ndata: b\n\n"
	err := scanSSE(strings.NewReader(input), func(d string) error { return sentinel })
	if !errors.Is(err, sentinel) {
		t.Fatalf("回调错误应原样上抛，实际: %v", err)
	}
}
