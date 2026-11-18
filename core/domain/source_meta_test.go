package domain

import (
	"strings"
	"testing"
)

// 默认值必须与 Legado 原生实体一致：enabledExplore/enabledCookieJar 缺省 true，
// respondTime 缺省 180000。这里守的是「导入的老书源 JSON 常常没写这几个字段」，
// 若解析成 Go 零值，界面会把所有源都显示成「未开启发现」。
func TestParseSourceMetaDefaults(t *testing.T) {
	meta := ParseSourceMeta(`{"bookSourceUrl":"https://a.example.com"}`)
	if !meta.EnabledExplore {
		t.Error("enabledExplore 缺省应为 true")
	}
	if !meta.EnabledCookie {
		t.Error("enabledCookieJar 缺省应为 true")
	}
	if meta.RespondTime != 180000 {
		t.Errorf("respondTime 缺省应为 180000，得到 %d", meta.RespondTime)
	}
	if meta.HasExploreURL || meta.HasLoginURL {
		t.Error("没有 exploreUrl/loginUrl 时不应标记为有")
	}
}

func TestParseSourceMetaExplicitValues(t *testing.T) {
	raw := `{
		"bookSourceType": 2,
		"enabledExplore": false,
		"exploreUrl": "https://a.example.com/find",
		"loginUrl": "  ",
		"enabledCookieJar": false,
		"weight": 7,
		"respondTime": 900,
		"variableComment": "填账号",
		"bookSourceGroup": "A,B"
	}`
	meta := ParseSourceMeta(raw)
	if meta.Type != 2 || meta.EnabledExplore || meta.EnabledCookie {
		t.Errorf("显式值未生效: %+v", meta)
	}
	if !meta.HasExploreURL {
		t.Error("exploreUrl 非空应标记为有")
	}
	if meta.HasLoginURL {
		t.Error("loginUrl 全是空白时不算配置了登录")
	}
	if meta.Weight != 7 || meta.RespondTime != 900 {
		t.Errorf("weight/respondTime 解析错误: %+v", meta)
	}
	if meta.Group != "A,B" || meta.VariableComment != "填账号" {
		t.Errorf("分组/变量说明解析错误: %+v", meta)
	}
}

func TestParseSourceMetaBrokenRaw(t *testing.T) {
	for _, raw := range []string{"", "   ", "not json", "[1,2,3]"} {
		meta := ParseSourceMeta(raw)
		if !meta.EnabledExplore || meta.RespondTime != 180000 {
			t.Errorf("坏 Raw(%q) 应回落到默认摘要，得到 %+v", raw, meta)
		}
	}
}

// PatchSourceRaw 用 UseNumber 解析，避免 respondTime 这类整数被写成 1.8e+06。
// 这个坑很隐蔽：Legado 端能解析回去，但导出给人工看时全是科学计数法。
func TestPatchSourceRawKeepsNumberFormat(t *testing.T) {
	raw := `{"bookSourceUrl":"https://a","respondTime":1800000,"weight":3}`
	out, err := PatchSourceRaw(raw, map[string]any{"enabledExplore": false})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "e+") || strings.Contains(out, "1.8e") {
		t.Errorf("数字被写成了科学计数法: %s", out)
	}
	if !strings.Contains(out, `"respondTime":1800000`) {
		t.Errorf("respondTime 原文丢失: %s", out)
	}
	if !strings.Contains(out, `"enabledExplore":false`) {
		t.Errorf("补丁未写入: %s", out)
	}
}

// 未知字段必须原样保留：桌面端不认识上游新增字段，不能因为改一次分组就抹掉。
func TestPatchSourceRawKeepsUnknownFields(t *testing.T) {
	raw := `{"bookSourceUrl":"https://a","futureField":{"x":1}}`
	out, err := PatchSourceRaw(raw, map[string]any{"bookSourceGroup": "G"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "futureField") {
		t.Errorf("未知字段丢失: %s", out)
	}
}

func TestPatchSourceRawEmptyAndBroken(t *testing.T) {
	out, err := PatchSourceRaw("", map[string]any{"bookSourceGroup": "G"})
	if err != nil || !strings.Contains(out, "bookSourceGroup") {
		t.Errorf("空 Raw 应能生成对象: out=%q err=%v", out, err)
	}
	if _, err := PatchSourceRaw("not json", map[string]any{"a": 1}); err == nil {
		t.Error("非法 JSON 应返回错误，而不是静默覆盖")
	}
}

func TestSplitGroups(t *testing.T) {
	cases := map[string][]string{
		"":          {},
		"  ":        {},
		"A":         {"A"},
		"A,B":       {"A", "B"},
		" A , , B ": {"A", "B"},
		"A,A,A":     {"A"},
	}
	for in, want := range cases {
		got := SplitGroups(in)
		if len(got) != len(want) {
			t.Fatalf("SplitGroups(%q)=%v，期望 %v", in, got, want)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("SplitGroups(%q)=%v，期望 %v", in, got, want)
			}
		}
	}
}

func TestAddRemoveGroup(t *testing.T) {
	if got := AddGroup("A", "B"); got != "A,B" {
		t.Errorf("AddGroup = %q", got)
	}
	if got := AddGroup("A,B", "A"); got != "A,B" {
		t.Errorf("重复添加不应改变: %q", got)
	}
	if got := AddGroup("", "A"); got != "A" {
		t.Errorf("空分组串添加: %q", got)
	}
	if got := RemoveGroup("A,B", "A"); got != "B" {
		t.Errorf("RemoveGroup = %q", got)
	}
	if got := RemoveGroup("A", "A"); got != "" {
		t.Errorf("移除唯一分组应为空: %q", got)
	}
	if got := RemoveGroup("A,B", "C"); got != "A,B" {
		t.Errorf("移除不存在的分组不应改变: %q", got)
	}
	if !HasGroup("A,B", "B") || HasGroup("A,B", "C") {
		t.Error("HasGroup 判定错误")
	}
}

func TestRenameGroup(t *testing.T) {
	cases := []struct {
		group, oldName, newName, want string
	}{
		{"小说", "小说", "文学", "文学"},
		// 多分组：原位替换，不能把改名的分组甩到末尾
		{"小说,推荐", "小说", "文学", "文学,推荐"},
		{"推荐,小说", "小说", "文学", "推荐,文学"},
		// newName 为空 = 删掉这个分组（分组管理的「删除」走这里）
		{"小说,推荐", "小说", "", "推荐"},
		{"小说", "小说", "", ""},
		// 改名撞上已有分组时去重
		{"A,B", "A", "B", "B"},
		// 没有命中 / 参数为空都不该动原值
		{"A,B", "C", "D", "A,B"},
		{"A,B", "", "D", "A,B"},
	}
	for _, c := range cases {
		if got := RenameGroup(c.group, c.oldName, c.newName); got != c.want {
			t.Errorf("RenameGroup(%q,%q,%q) = %q, 期望 %q", c.group, c.oldName, c.newName, got, c.want)
		}
	}
}
