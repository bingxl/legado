package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/legado/legado-go/pkg/config"
	"github.com/legado/legado-go/pkg/source"
)

// 校验/日志前缀符号，对齐客户端风格
const (
	markOK    = "✓"
	markInfo  = "·"
	markWarn  = "!"
	markError = "✗"
)

// —— 退出与报错 ——
//
// 子命令里的「打印错误后退出」统一走这两个函数，避免到处写
// fmt.Fprintln(os.Stderr, ...) + os.Exit(1)。
// 注意 os.Exit 不执行 defer，Cookie 只能由 main 的正常返回路径落盘。

// failf 打印一行错误并退出（状态码 1）
func failf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

// failErr 打印「<动作>失败: <err>」并退出（状态码 1）
func failErr(action string, err error) {
	failf("%s失败: %v", action, err)
}

// —— 校验结果输出 ——
//
// source.Issue 与 config.Issue 是两套类型（等级枚举也不同），
// 这里把它们归一成 issueLine，打印逻辑只写一份。

type issueLine struct {
	mark string
	text string
}

func sourceIssueLines(issues []source.Issue) []issueLine {
	lines := make([]issueLine, 0, len(issues))
	for _, i := range issues {
		mark := markInfo
		switch i.Level {
		case source.LevelError:
			mark = markError
		case source.LevelWarn:
			mark = markWarn
		}
		lines = append(lines, issueLine{mark: mark, text: i.String()})
	}
	return lines
}

func configIssueLines(issues []config.Issue) []issueLine {
	lines := make([]issueLine, 0, len(issues))
	for _, i := range issues {
		mark := markInfo
		switch i.Level {
		case config.LevelError:
			mark = markError
		case config.LevelWarn:
			mark = markWarn
		}
		lines = append(lines, issueLine{mark: mark, text: i.String()})
	}
	return lines
}

// printIssueLines 缩进输出校验项；没有问题时打印一行 ✓
func printIssueLines(lines []issueLine) {
	if len(lines) == 0 {
		fmt.Printf("   %s 无问题\n", markOK)
		return
	}
	for _, l := range lines {
		fmt.Printf("   %s %s\n", l.mark, l.text)
	}
}

// printSourceIssues 输出「── 名称 <地址>」标题与该校验项
func printSourceIssues(name, url string, lines []issueLine) {
	fmt.Printf("── %s <%s>\n", name, url)
	printIssueLines(lines)
}

// printFlagUsage 是单个子命令的 -h 输出：本命令的选项 + 出口提示
func printFlagUsage(fs *flag.FlagSet, name string) {
	w := fs.Output()
	fmt.Fprintf(w, "用法: legado %s [选项]\n\n选项:\n", name)
	fs.PrintDefaults()
	fmt.Fprintln(w, "\n完整命令说明见 legado help")
}

// —— 文本排版小工具 ——

// dispWidth 计算终端显示宽度（中日韩全角字符按 2 列）
func dispWidth(s string) int {
	w := 0
	for _, r := range s {
		switch {
		case r >= 0x1100 && r <= 0x115f, // 谚文字母
			r == 0x2329, r == 0x232a,
			r >= 0x2e80 && r <= 0xa4cf, // CJK 部首、假名、汉字
			r >= 0xac00 && r <= 0xd7a3, // 谚文音节
			r >= 0xf900 && r <= 0xfaff, // CJK 兼容汉字
			r >= 0xfe30 && r <= 0xfe6f, // CJK 兼容形式
			r >= 0xff00 && r <= 0xff60, // 全角形式
			r >= 0xffe0 && r <= 0xffe6:
			w += 2
		default:
			w++
		}
	}
	return w
}

// pad 用空格把 s 补齐到 width 显示列
func pad(s string, width int) string {
	if d := dispWidth(s); d < width {
		return s + strings.Repeat(" ", width-d)
	}
	return s
}

// firstLine 把多行文本压成一行，并按字数截断
func firstLine(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	runes := []rune(s)
	if len(runes) > n {
		return string(runes[:n]) + "…"
	}
	return s
}
