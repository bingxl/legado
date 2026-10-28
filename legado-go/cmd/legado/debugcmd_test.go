package main

import (
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/util"
)

func TestParseDbgStage(t *testing.T) {
	cases := map[string]dbgStage{
		"":          dbgStageContent,
		"all":       dbgStageContent,
		"search":    dbgStageSearch,
		"explore":   dbgStageExplore,
		"info":      dbgStageInfo,
		"detail":    dbgStageInfo,
		"toc":       dbgStageToc,
		"catalog":   dbgStageToc,
		"content":   dbgStageContent,
		" CHAPTER ": dbgStageContent,
	}
	for in, want := range cases {
		got, err := parseDbgStage(in)
		if err != nil {
			t.Errorf("parseDbgStage(%q) 报错: %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("parseDbgStage(%q) = %v，期望 %v", in, got, want)
		}
	}
	if _, err := parseDbgStage("everything"); err == nil {
		t.Error("非法取值应报错")
	}
}

// 调试入口按 URL 形态分派，依赖 util.IsAbsUrl 的判断
func TestIsAbsURL(t *testing.T) {
	cases := map[string]bool{
		"http://a.com/x":  true,
		"https://a.com/x": true,
		"HTTP://A.COM":    true,
		"a.com/x":         false,
		"++http://a.com":  false,
		"":                false,
	}
	for in, want := range cases {
		if got := util.IsAbsUrl(in); got != want {
			t.Errorf("util.IsAbsUrl(%q) = %v，期望 %v", in, got, want)
		}
	}
}

func TestExploreURL(t *testing.T) {
	src := &model.BookSource{
		BookSourceUrl: "https://a.com",
		ExploreUrl:    "冒险::https://a.com/sort/1\n热血::https://a.com/sort/2",
	}
	d := &dbgRun{src: src}

	cases := []struct {
		name        string
		prefix, url string
		want        string
		wantErr     string
	}{
		{"空分类空地址取第一个", "", "", "https://a.com/sort/1", ""},
		{"按分类名取地址", "热血", "", "https://a.com/sort/2", ""},
		{"显式地址优先", "热血", "https://b.com/x", "https://b.com/x", ""},
		{"分类不存在", "不存在", "", "", "可选"},
	}
	for _, c := range cases {
		got, err := d.exploreURL(c.prefix, c.url)
		if c.wantErr != "" {
			if err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("%s: 期望错误含 %q，实际 err=%v url=%q", c.name, c.wantErr, err, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: 意外错误 %v", c.name, err)
			continue
		}
		if got != c.want {
			t.Errorf("%s: 地址 = %q，期望 %q", c.name, got, c.want)
		}
	}
}

// 没有 exploreUrl 的源调发现页调试时要给出可操作的提示，而不是空地址
func TestExploreURLWithoutExplore(t *testing.T) {
	d := &dbgRun{src: &model.BookSource{BookSourceUrl: "https://a.com"}}
	_, err := d.exploreURL("", "")
	if err == nil || !strings.Contains(err.Error(), "exploreUrl") {
		t.Errorf("应提示源没有 exploreUrl，实际: %v", err)
	}
}

func TestDbgRunAllow(t *testing.T) {
	d := &dbgRun{max: dbgStageToc}
	if !d.allow(dbgStageSearch) || !d.allow(dbgStageToc) {
		t.Error("未超过上限的阶段应允许")
	}
	if d.allow(dbgStageContent) {
		t.Error("超过上限的阶段应被拦住")
	}
}
