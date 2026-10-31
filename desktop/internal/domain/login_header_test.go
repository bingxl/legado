package domain

import (
	"errors"
	"strings"
	"testing"
)

// 用户粘贴的登录头形态极不统一，解析必须宽容。
func TestParseLoginHeader(t *testing.T) {
	cases := []struct {
		name   string
		in     string
		cookie string // 期望的 Cookie（空表示不该有）
		ua     string
	}{
		{"JSON", `{"Cookie":"sid=1","User-Agent":"UA1"}`, "sid=1", "UA1"},
		{"请求头行", "Cookie: sid=2\nUser-Agent: UA2", "sid=2", "UA2"},
		{"裸 Cookie", "sid=3; token=4", "sid=3; token=4", ""},
		{"键名大小写", `{"cookie":"SID=5","user-agent":"UA5"}`, "SID=5", "UA5"},
		{"CRLF 头行", "Cookie: sid=6\r\n", "sid=6", ""},
		{"Cookie 值里有冒号", "Cookie: a=1:2", "a=1:2", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m, err := ParseLoginHeader(c.in)
			if err != nil {
				t.Fatalf("解析失败: %v", err)
			}
			if got := CookieFromLoginHeader(m); got != c.cookie {
				t.Fatalf("Cookie 应为 %q，得到 %q（%#v）", c.cookie, got, m)
			}
			if c.ua != "" && m["User-Agent"] != c.ua {
				t.Fatalf("UA 应为 %q，得到 %q", c.ua, m["User-Agent"])
			}
		})
	}

	if _, err := ParseLoginHeader("   "); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("空内容应返回参数错误, 得到 %v", err)
	}
	if _, err := ParseLoginHeader(`{"Cookie":}`); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("坏 JSON 应返回参数错误, 得到 %v", err)
	}
}

// 存库的形态要规范化：同一份内容不论用户怎么粘，落库结果都一致。
func TestLoginHeaderJSONNormalized(t *testing.T) {
	m1, _ := ParseLoginHeader(`{"cookie":"sid=1","user-agent":"UA"}  `)
	m2, _ := ParseLoginHeader("Cookie: sid=1\nUser-Agent: UA")

	j1, j2 := LoginHeaderJSON(m1), LoginHeaderJSON(m2)
	if j1 != j2 {
		t.Fatalf("规范化结果不一致:\n%s\n%s", j1, j2)
	}
	if !strings.Contains(j1, `"Cookie":"sid=1"`) {
		t.Fatalf("键名未归一: %s", j1)
	}
	// 顺序稳定：重新解析再序列化应得到同一串（界面显示不会跳来跳去）。
	again, _ := ParseLoginHeader(j1)
	if LoginHeaderJSON(again) != j1 {
		t.Fatalf("序列化不稳定: %s", LoginHeaderJSON(again))
	}
	if LoginHeaderJSON(nil) != "" {
		t.Fatal("空 map 应返回空串")
	}
}

// Cookie 掩码：界面不能把登录态原样打在屏幕上。
func TestMaskCookie(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", ""},
		{"sid=abcdefghij", "sid=abcd…"},
		{"sid=abc; token=def", "sid=abc（共 2 项，18 字节）"},
		{"nonsense", "（1 项，共 8 字节）"},
	}
	for _, c := range cases {
		if got := MaskCookie(c.in); got != c.want {
			t.Fatalf("MaskCookie(%q) = %q，期望 %q", c.in, got, c.want)
		}
	}
	// 掩码里不能出现完整值。
	if strings.Contains(MaskCookie("sid=supersecretvalue"), "supersecretvalue") {
		t.Fatal("掩码泄露了完整 Cookie")
	}
}
