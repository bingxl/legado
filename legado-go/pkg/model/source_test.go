package model

import (
	"strings"
	"testing"
)

// 发现分类的静态解析。JS 形式（@js: / <js>）在 webbook 包测试。
func TestParseExploreKinds(t *testing.T) {
	// JSON 数组（Legado 导出格式）
	s := `[{"title":"全部","url":"/comics?tag=全部&page={{page}}"},{"title":"新作","url":"/new"}]`
	kinds := ParseExploreKinds(s)
	if len(kinds) != 2 || kinds[0].Title != "全部" || kinds[1].Url != "/new" {
		t.Fatalf("JSON 数组解析错误: %#v", kinds)
	}

	// 单个对象
	if k := ParseExploreKinds(`{"title":"单","url":"/one"}`); len(k) != 1 || k[0].Url != "/one" {
		t.Fatalf("JSON 对象解析错误: %#v", k)
	}

	// 按行「分类名::地址」
	k := ParseExploreKinds("玄幻::/xuanhuan\n都市::/dushi")
	if len(k) != 2 || k[1].Title != "都市" || k[1].Url != "/dushi" {
		t.Fatalf("按行解析错误: %#v", k)
	}

	// 裸地址行：整段是**分类名**而不是地址（与 Legado 原版一致：
	// `kindCfg.getOrNull(1)` 为空 → url 为空），保留为分组标题供 UI 分组，
	// 但选默认地址时必须跳过它（FirstExploreURL / webbook.firstExploreUrl）。
	if k := ParseExploreKinds("/only"); len(k) != 1 || !k[0].IsGroup() || k[0].Title != "/only" {
		t.Fatalf("裸地址行应保留为分组标题, 得到 %#v", k)
	}

	// && 分隔与分组标题混排：分组标题（无地址）保留，其余照常解析
	mixed := "{'title':'总榜','url':''}&&'总点击榜'::/rank/allvisit_{{page}}&&'最近更新'::/rank/lastupdate_{{page}}"
	if k := ParseExploreKinds(mixed); len(k) != 3 {
		t.Fatalf("&& 分隔解析错误: %#v", k)
	} else if !k[0].IsGroup() || k[2].Url != "/rank/lastupdate_{{page}}" {
		t.Fatalf("分组标题/末段解析错误: %#v", k)
	}

	// 空
	if k := ParseExploreKinds(""); len(k) != 0 {
		t.Fatalf("空 exploreUrl 应为空, 得到 %#v", k)
	}
}

// 真实书源（猫耳 FM）的 exploreUrl：手写 JS 对象字面量，不是严格 JSON。
//
// 这条一旦回退成 encoding/json，整段会被当成一个分类（标题是整段源码），
// 发现页展开后一个都点不开——表面上「书源有发现」，实际全坏。
func TestParseExploreKindsJSLiteral(t *testing.T) {
	raw := `[
{'title':'全年龄•全部','url':'https://www.missevan.com/dramaapi/filter?filters=0_0_0_0_0&page={{page}}&order=1&page_size=20','style':{layout_flexGrow:1,layout_flexBasisPercent:1}},
{'title':'全年龄•言情','url':'https://www.missevan.com/dramaapi/filter?filters=0_0_0_6_0&page={{page}}&order=1&page_size=20','style':{layout_flexGrow:1,layout_flexBasisPercent:0.4}},
{'title':'全一期•全部','url':'https://www.missevan.com/dramaapi/filter?filters=0_0_3_0_0&page={{page}}&order=1&page_size=20','style':{layout_flexGrow:1,layout_flexBasisPercent:1}},
]`
	kinds := ParseExploreKinds(raw)
	if len(kinds) != 3 {
		t.Fatalf("应为 3 个分类，实际 %d 个: %#v", len(kinds), kinds)
	}
	if kinds[0].Title != "全年龄•全部" || !strings.Contains(kinds[0].Url, "filters=0_0_0_0_0") {
		t.Fatalf("第 1 个分类解析错误: %#v", kinds[0])
	}
	if kinds[1].Title != "全年龄•言情" || !strings.Contains(kinds[1].Url, "page={{page}}") {
		t.Fatalf("第 2 个分类解析错误: %#v", kinds[1])
	}
	// style 也要跟着解析出来（布局信息，原版 FlexChildStyle）
	if m, ok := kinds[0].Style.(map[string]any); !ok || m["layout_flexBasisPercent"] != float64(1) {
		t.Fatalf("style 解析错误: %#v", kinds[0].Style)
	}
	// 所有分类都该带真实地址，不能是分组标题
	for i, k := range kinds {
		if k.IsGroup() {
			t.Fatalf("第 %d 个分类没有地址: %#v", i, k)
		}
	}
}

// -ua / Config.UserAgent 应能覆盖默认 UA；但书源 header 里显式写的 UA 优先
func TestDefaultUserAgentOverride(t *testing.T) {
	old := DefaultUserAgent
	defer func() { DefaultUserAgent = old }()
	DefaultUserAgent = "MyUA/1.0"

	if got := (&BookSource{}).GetHeaderMap()["User-Agent"]; got != "MyUA/1.0" {
		t.Fatalf("默认 UA 未生效，得到 %q", got)
	}
	src := &BookSource{Header: `{"User-Agent":"SrcUA/2.0"}`}
	if got := src.GetHeaderMap()["User-Agent"]; got != "SrcUA/2.0" {
		t.Fatalf("书源 header 的 UA 应优先，得到 %q", got)
	}
}

// header 也常被手写成宽松 JSON（裸键 / 单引号），原版靠 GSON lenient 吃掉。
// 严格解析会整份丢弃 header，表现为「书源全站 403，但浏览器打开正常」。
func TestGetHeaderMapLoose(t *testing.T) {
	src := &BookSource{Header: `{
		User-Agent: 'UA/9.9',
		'Referer': 'https://a.example.com/list',
		"X-Count": 3,
	}`}
	m := src.GetHeaderMap()
	if m["User-Agent"] != "UA/9.9" {
		t.Fatalf("裸键 User-Agent 未解析: %#v", m)
	}
	if m["Referer"] != "https://a.example.com/list" {
		t.Fatalf("单引号 Referer 未解析: %#v", m)
	}
	if m["X-Count"] != "3" {
		t.Fatalf("数字值应按原版语义转成字符串: %#v", m)
	}
}

// enabledCookieJar 缺省时按 Kotlin 原版的默认值 true 处理。
// 这条一旦回退成 false，登录脚本里 java.post 拿到的 Set-Cookie 就不会落盘，
// 表现为「登录成功但一刷新就掉登录态」，排查成本极高。
func TestEnabledCookieJarDefault(t *testing.T) {
	on, off := true, false

	if !(&BookSource{}).EnabledCookieJarOn() {
		t.Fatal("字段缺省时应视为开启")
	}
	if !(&BookSource{EnabledCookieJar: &on}).EnabledCookieJarOn() {
		t.Fatal("显式 true 时应为开启")
	}
	if (&BookSource{EnabledCookieJar: &off}).EnabledCookieJarOn() {
		t.Fatal("显式 false 时应为关闭")
	}
}
