package util

import "testing"

// 书源正则从页面里抠出的 base64 常带 JS/JSON 转义：
// 浏览器里 `'...Kc\/nzf...'` 解析后是 `...Kc/nzf...`，
// 引擎拿到的是带反斜杠的原文，不还原就 base64 解码失败（表现为「结果是空」）。
func TestUnescapeJSString(t *testing.T) {
	cases := []struct{ in, want string }{
		{"abc", "abc"},
		{`a\/b`, "a/b"},
		{`\u002b`, "+"},
		{`a\u0041b`, "aAb"},
		{`\/VCvRfaRWAo2\u002bYad1`, "/VCvRfaRWAo2+Yad1"},
		{`it\'s`, "it's"},
		{`a\\b`, `a\b`},
		{`a\nb`, "a\nb"},
		{`\x41`, "A"},
		{`\`, `\`},          // 结尾孤立反斜杠
		{`\uZZZZ`, "uZZZZ"}, // 非法转义原样保留（丢掉反斜杠）
	}
	for _, c := range cases {
		if got := UnescapeJSString(c.in); got != c.want {
			t.Errorf("UnescapeJSString(%q) = %q，期望 %q", c.in, got, c.want)
		}
	}
}

// 还原后再 base64 解码应成功。
func TestUnescapeThenBase64(t *testing.T) {
	if b := Base64DecodeBytes(UnescapeJSString(`aGVsbG8gd29ybGQ=`)); string(b) != "hello world" {
		t.Fatalf("解码失败: %q", b)
	}
}
