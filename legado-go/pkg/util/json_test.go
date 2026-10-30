package util

import "testing"

// @put:{...} 的书源写法几乎都不加引号，解析必须宽松（GSON lenient 语义）。
func TestParseLooseStringMap(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want map[string]string
		ok   bool
	}{
		{"标准 JSON", `{"book":"id"}`, map[string]string{"book": "id"}, true},
		{"裸键裸值", `{book:id}`, map[string]string{"book": "id"}, true},
		{"规则值", `{bid:@css:span.id@text}`, map[string]string{"bid": "@css:span.id@text"}, true},
		{"多个键", `{a:1, b:$.name}`, map[string]string{"a": "1", "b": "$.name"}, true},
		{"值含 URL", `{u:http://x.com/a?b=1}`, map[string]string{"u": "http://x.com/a?b=1"}, true},
		{"空对象", `{}`, map[string]string{}, false},
		{"空值", `{k:}`, map[string]string{"k": ""}, true},
	}
	for _, c := range cases {
		got, ok := ParseLooseStringMap(c.in)
		if ok != c.ok {
			t.Fatalf("%s: ok 应为 %v，实际 %v（%v）", c.name, c.ok, ok, got)
		}
		if len(got) != len(c.want) {
			t.Fatalf("%s: 期望 %v，实际 %v", c.name, c.want, got)
		}
		for k, v := range c.want {
			if got[k] != v {
				t.Fatalf("%s: 键 %s 应为 %q，实际 %q", c.name, k, v, got[k])
			}
		}
	}
}
