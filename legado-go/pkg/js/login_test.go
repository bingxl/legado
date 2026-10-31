package js

import (
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/model"
)

// 登录脚本靠 source.getLoginInfoMap() 取用户在登录框里填的账号密码。
// 绑定缺失时脚本会静默拿到空对象，登录请求带着空密码发出去——典型的
// 「点登录没反应也不报错」，所以这里把键值透传钉住。
func TestSourceGetLoginInfoMap(t *testing.T) {
	src := &model.BookSource{BookSourceUrl: "https://demo.test", BookSourceName: "演示"}
	b := &Bindings{
		Source: src,
		LoginInfo: func() map[string]string {
			return map[string]string{"账号": "reader", "密码": "p@ss"}
		},
	}

	out, err := DefaultEngine().Eval(`
		var m = source.getLoginInfoMap();
		m['账号'] + "/" + m['密码']
	`, b)
	if err != nil {
		t.Fatalf("执行失败: %v", err)
	}
	if got := valStr(out); got != "reader/p@ss" {
		t.Fatalf("登录信息未透传, 得到 %q", got)
	}

	// 没有登录信息回调时必须是空对象而不是报错：
	// 普通规则（非登录场景）也会走到 source 对象。
	out, err = DefaultEngine().Eval(`Object.keys(source.getLoginInfoMap()).length`, &Bindings{Source: src})
	if err != nil {
		t.Fatalf("无回调时执行失败: %v", err)
	}
	if got := valStr(out); got != "0" {
		t.Fatalf("无回调时应为空对象, 得到 %q", got)
	}
}

// 一部分书源的 login 函数会自己拼登录头并调 source.putLoginHeader 落盘。
func TestSourcePutLoginHeader(t *testing.T) {
	var saved string
	b := &Bindings{
		Source:        &model.BookSource{BookSourceUrl: "https://demo.test"},
		SetLoginHeader: func(h string) error { saved = h; return nil },
	}
	out, err := DefaultEngine().Eval(`source.putLoginHeader('{"Cookie":"sid=1"}')`, b)
	if err != nil {
		t.Fatalf("执行失败: %v", err)
	}
	if valStr(out) != "true" || saved != `{"Cookie":"sid=1"}` {
		t.Fatalf("登录头未保存, 返回 %q 保存 %q", valStr(out), saved)
	}

	// 未注入回调时应返回 false，而不是 panic。
	out, err = DefaultEngine().Eval(`source.putLoginHeader('{}')`, &Bindings{Source: &model.BookSource{}})
	if err != nil {
		t.Fatalf("无回调时执行失败: %v", err)
	}
	if valStr(out) != "false" {
		t.Fatalf("无回调时应返回 false, 得到 %q", valStr(out))
	}
}

// 登录时的脚本日志要能回显给用户（否则登录失败只剩一句「登录出错」）。
// LogHook 必须优先于包级 OnLog，且不能污染全局。
func TestLogHookTakesPrecedence(t *testing.T) {
	var hooked, global []string
	old := OnLog
	OnLog = func(msg string) { global = append(global, msg) }
	defer func() { OnLog = old }()

	b := &Bindings{
		Source:  &model.BookSource{BookSourceUrl: "https://demo.test"},
		LogHook: func(msg string) { hooked = append(hooked, msg) },
	}
	if _, err := DefaultEngine().Eval(`java.log("登录中")`, b); err != nil {
		t.Fatalf("执行失败: %v", err)
	}
	if len(hooked) != 1 || !strings.Contains(hooked[0], "登录中") {
		t.Fatalf("日志未进入钩子: %#v", hooked)
	}
	if len(global) != 0 {
		t.Fatalf("钩子存在时不应写全局: %#v", global)
	}
}
