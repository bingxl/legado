package main

import (
	"flag"
	"reflect"
	"testing"

	"github.com/legado/legado-go/pkg/source"
)

// 别名必须指向同一个实现，且 config 系列命令自己管配置文件
func TestCommandTable(t *testing.T) {
	same := func(a, b string) bool {
		ca, ok := commands[a]
		if !ok {
			t.Fatalf("命令表缺少 %q", a)
		}
		cb, ok := commands[b]
		if !ok {
			t.Fatalf("命令表缺少 %q", b)
		}
		return reflect.ValueOf(ca.run).Pointer() == reflect.ValueOf(cb.run).Pointer()
	}

	if !same("validate", "check") {
		t.Error("check 应等价于 validate")
	}
	if !same("list", "sources") {
		t.Error("sources 应等价于 list")
	}

	selfManaged := map[string]bool{"config": true, "config-gen": true, "config-check": true}
	for name, c := range commands {
		if c.run == nil {
			t.Errorf("命令 %q 没有实现", name)
		}
		if c.withoutConfig != selfManaged[name] {
			t.Errorf("命令 %q 的 withoutConfig = %v，期望 %v", name, c.withoutConfig, selfManaged[name])
		}
	}
}

func TestIsHelpArg(t *testing.T) {
	yes := []string{"help", "-h", "-help", "--help", "HELP", "Help"}
	no := []string{"", "hel", "list", "-helpme", "config"}

	for _, s := range yes {
		if !isHelpArg(s) {
			t.Errorf("isHelpArg(%q) 应为 true", s)
		}
	}
	for _, s := range no {
		if isHelpArg(s) {
			t.Errorf("isHelpArg(%q) 应为 false", s)
		}
	}
}

func TestArgOr(t *testing.T) {
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	book := fs.String("book", "", "")
	_ = fs.Parse([]string{"https://a.com/1"})

	argOr(fs, book)
	if *book != "https://a.com/1" {
		t.Errorf("位置参数未补进 -book，实际 %q", *book)
	}

	// 已经给了 -book 时，位置参数不应覆盖它
	fs2 := flag.NewFlagSet("t", flag.ContinueOnError)
	book2 := fs2.String("book", "", "")
	_ = fs2.Parse([]string{"-book", "https://a.com/2", "https://a.com/3"})
	argOr(fs2, book2)
	if *book2 != "https://a.com/2" {
		t.Errorf("-book 被位置参数覆盖了，实际 %q", *book2)
	}
}

// 校验符号映射：三个等级各有独立符号，未知等级按提示处理
func TestIssueMarks(t *testing.T) {
	lines := sourceIssueLines([]source.Issue{
		{Level: source.LevelError},
		{Level: source.LevelWarn},
		{Level: source.LevelInfo},
	})
	want := []string{markError, markWarn, markInfo}
	if len(lines) != len(want) {
		t.Fatalf("行数 = %d，期望 %d", len(lines), len(want))
	}
	for i, w := range want {
		if lines[i].mark != w {
			t.Errorf("第 %d 行符号 = %q，期望 %q", i, lines[i].mark, w)
		}
	}
}
