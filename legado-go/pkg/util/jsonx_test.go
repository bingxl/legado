package util

import (
	"reflect"
	"testing"
)

type looseKind struct {
	Title string         `json:"title"`
	URL   string         `json:"url"`
	Style map[string]any `json:"style"`
}

// 书源里的 exploreUrl 绝大多数是「手写 JS 对象字面量」，不是严格 JSON。
// 这些写法在 Kotlin 侧靠 GSON lenient 全部能吃下，Go 侧必须同样支持。
func TestUnmarshalLooseJSON_ExploreKinds(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want []looseKind
	}{
		{
			name: "严格 JSON",
			raw:  `[{"title":"全部","url":"/all"}]`,
			want: []looseKind{{Title: "全部", URL: "/all"}},
		},
		{
			name: "单引号 + 裸键",
			raw:  `[{title:'全部',url:'/all'}]`,
			want: []looseKind{{Title: "全部", URL: "/all"}},
		},
		{
			name: "嵌套裸键 style",
			raw:  `[{title:'全年龄•全部',url:'https://a.com/f?page={{page}}',style:{layout_flexGrow:1,layout_flexBasisPercent:1}}]`,
			want: []looseKind{{
				Title: "全年龄•全部",
				URL:   "https://a.com/f?page={{page}}",
				Style: map[string]any{"layout_flexGrow": float64(1), "layout_flexBasisPercent": float64(1)},
			}},
		},
		{
			name: "尾随逗号",
			raw:  `[{title:'A',url:'/a'},{title:'B',url:'/b'},]`,
			want: []looseKind{{Title: "A", URL: "/a"}, {Title: "B", URL: "/b"}},
		},
		{
			name: "注释与换行",
			raw: "[\n // 分组标题\n {'title':'完结','url':''},\n /* 子分类 */\n {'title':'玄幻','url':'/x'},\n]",
			want: []looseKind{{Title: "完结"}, {Title: "玄幻", URL: "/x"}},
		},
		{
			name: "裸值字符串（未加引号的 URL）",
			raw:  `[{title:全部,url:http://a.com/all}]`,
			want: []looseKind{{Title: "全部", URL: "http://a.com/all"}},
		},
		{
			name: "值里含冒号与逗号之外的分隔符",
			raw:  `[{title:'玄,幻',url:'/x?a=1&b=2'}]`,
			want: []looseKind{{Title: "玄,幻", URL: "/x?a=1&b=2"}},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var got []looseKind
			if err := UnmarshalLooseJSON(c.raw, &got); err != nil {
				t.Fatalf("解析失败: %v", err)
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("结果 %#v，期望 %#v", got, c.want)
			}
		})
	}
}

func TestParseLooseJSON_TopLevel(t *testing.T) {
	// 顶层单对象（部分书源把单个分类写成对象而非数组）
	var one looseKind
	if err := UnmarshalLooseJSON(`{title:'单条',url:'/one'}`, &one); err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if one.Title != "单条" || one.URL != "/one" {
		t.Fatalf("结果 %#v", one)
	}

	// 字符串转义
	var m map[string]string
	if err := UnmarshalLooseJSON(`{'a':'x\'y','b':'换\n行','c':"引号\"内"`, &m); err == nil {
		t.Fatal("未闭合字符串应当报错")
	}
	if err := UnmarshalLooseJSON(`{'a':'x\'y','b':'line1\nline2'}`, &m); err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if m["a"] != "x'y" || m["b"] != "line1\nline2" {
		t.Fatalf("转义结果 %#v", m)
	}
}

func TestParseLooseJSON_Errors(t *testing.T) {
	bad := []string{
		`{"a":1`,
		`[1,2`,
		`{'a':}`,
		`[{"a":1} {"b":2}]`,
	}
	for _, s := range bad {
		if _, err := ParseLooseJSON(s); err == nil {
			t.Errorf("%q 应当解析失败", s)
		}
	}
}
