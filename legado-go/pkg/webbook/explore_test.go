package webbook

import (
	"testing"

	"github.com/legado/legado-go/pkg/model"
)

// exploreUrl 的 JS 形式必须被执行后再解析。
//
// 真实书源里绝大多数分类配置都是 JS：地址要拼签名、时间戳或分区参数，
// 只能算出来。只做静态解析会把整段脚本按行拆成同名分类——不报错，
// 但每个分类地址都是脚本片段，点进去必然失败。
func TestGetExploreKindsJS(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want []model.ExploreKind
	}{
		{
			name: "@js: 返回 JSON 字符串",
			raw:  `@js:JSON.stringify([{title:'全部',url:'/all'},{title:'新作',url:'/new_{{page}}'}])`,
			want: []model.ExploreKind{{Title: "全部", Url: "/all"}, {Title: "新作", Url: "/new_{{page}}"}},
		},
		{
			name: "<js> 包裹，直接返回数组",
			raw:  `<js>[{title:'玄幻',url:'/x'},{title:'都市',url:'/d'}]</js>`,
			want: []model.ExploreKind{{Title: "玄幻", Url: "/x"}, {Title: "都市", Url: "/d"}},
		},
		{
			name: "@js: 拼字符串（分类名::地址 行）",
			raw:  `@js:'玄幻::/x&&都市::/d'`,
			want: []model.ExploreKind{{Title: "玄幻", Url: "/x"}, {Title: "都市", Url: "/d"}},
		},
		{
			name: "静态 JSON 不走 JS",
			raw:  `[{"title":"全部","url":"/all"}]`,
			want: []model.ExploreKind{{Title: "全部", Url: "/all"}},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := GetExploreKinds(&model.BookSource{
				BookSourceUrl: "https://example.com",
				ExploreUrl:    c.raw,
			})
			if len(got) != len(c.want) {
				t.Fatalf("分类数量 %d，期望 %d: %#v", len(got), len(c.want), got)
			}
			for i := range c.want {
				if got[i].Title != c.want[i].Title || got[i].Url != c.want[i].Url {
					t.Fatalf("第 %d 个分类为 %#v，期望 %#v", i, got[i], c.want[i])
				}
			}
		})
	}
}

// JS 抛错时返回空列表而不是整段脚本冒充分类。
func TestGetExploreKindsJSError(t *testing.T) {
	src := &model.BookSource{
		BookSourceUrl: "https://example.com",
		ExploreUrl:    `@js:undefinedFn()`,
	}
	if got := GetExploreKinds(src); len(got) != 0 {
		t.Fatalf("JS 出错应返回空分类，实际 %#v", got)
	}
}
