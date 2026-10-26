package model

import "testing"

func TestGetExploreKinds(t *testing.T) {
	// JSON 数组（Legado 导出格式）
	s := &BookSource{ExploreUrl: `[{"title":"全部","url":"/comics?tag=全部&page={{page}}"},{"title":"新作","url":"/new"}]`}
	kinds := s.GetExploreKinds()
	if len(kinds) != 2 || kinds[0].Title != "全部" || kinds[1].Url != "/new" {
		t.Fatalf("JSON 数组解析错误: %#v", kinds)
	}

	// 单个对象
	s2 := &BookSource{ExploreUrl: `{"title":"单","url":"/one"}`}
	if k := s2.GetExploreKinds(); len(k) != 1 || k[0].Url != "/one" {
		t.Fatalf("JSON 对象解析错误: %#v", k)
	}

	// 按行「分类名::地址」
	s3 := &BookSource{ExploreUrl: "玄幻::/xuanhuan\n都市::/dushi"}
	if k := s3.GetExploreKinds(); len(k) != 2 || k[1].Title != "都市" || k[1].Url != "/dushi" {
		t.Fatalf("按行解析错误: %#v", k)
	}

	// 裸地址行
	s4 := &BookSource{ExploreUrl: "/only"}
	if k := s4.GetExploreKinds(); len(k) != 1 || k[0].Url != "/only" {
		t.Fatalf("裸地址解析错误: %#v", k)
	}

	// 空
	if k := (&BookSource{}).GetExploreKinds(); len(k) != 0 {
		t.Fatalf("空 exploreUrl 应为空, 得到 %#v", k)
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
