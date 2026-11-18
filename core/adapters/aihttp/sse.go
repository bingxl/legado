package aihttp

import (
	"bufio"
	"io"
	"strings"
)

// sseDone 是 OpenAI 兼容流式响应的终止标记。
const sseDone = "[DONE]"

// scanSSE 逐行解析 Server-Sent Events 流，把每个事件的 data 交给 onData。
//
// 只关心 data 行：event/id/retry 这些字段在对话补全里用不到，
// 忽略它们能让解析对各家实现的细微差异更宽容。
//
// 返回 nil 表示流正常读完（含收到 [DONE]）；onData 返回的错误原样上抛。
func scanSSE(r io.Reader, onData func(data string) error) error {
	sc := bufio.NewScanner(r)
	// 默认 64KB 的行上限不够用：一个分片的 JSON 在长段落里可达数百 KB，
	// 超限会让 Scanner 直接报 ErrTooLong，表现为「流式回答莫名中断」。
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)

	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(line[len("data:"):])
		if data == "" {
			continue
		}
		if data == sseDone {
			return nil
		}
		if err := onData(data); err != nil {
			return err
		}
	}
	return sc.Err()
}
