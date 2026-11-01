package webbook

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/debug"
	"github.com/legado/legado-go/pkg/model"
)

// 超星源在线回归（复刻 2026-11-01 桌面端「搜索/目录全空」事故）：
//  1. ruleSearch.bookList 用 `$.[*]`——jayway 容忍、ojg 不容忍的写法；
//  2. ruleToc.chapterList 用 `<js>…</js>li a` 组合规则——JS 产出的
//     HTML 字符串必须被后续选择器重新解析。
//
// 两处此前都在 legado-go 上静默失败，Kotlin 引擎正常。
// 网站不可达时跳过，不算失败。
func TestChaoxingLiveSource(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "超星书源_修复版.json"))
	if err != nil {
		t.Skipf("书源文件不存在: %v", err)
	}
	var list []*model.BookSource
	if err := json.Unmarshal(raw, &list); err != nil {
		t.Fatalf("书源解析失败: %v", err)
	}
	src := list[0]

	results, err := SearchBook(src, "三国演义", 1)
	if err != nil {
		t.Skipf("搜索失败（多半是网络不可达）: %v", err)
	}
	if len(results) == 0 {
		t.Fatal("搜索结果为空：$.[*] 归一化失效？")
	}
	book := results[0].ToBook()
	if book.Name == "" || book.BookUrl == "" {
		t.Fatalf("搜索结果字段缺失: name=%q bookUrl=%q", book.Name, book.BookUrl)
	}

	if err := GetBookInfo(src, book); err != nil {
		t.Logf("详情失败（继续测目录）: %v", err)
	}

	chapters, err := GetChapterList(src, book, false)
	if err != nil {
		if strings.Contains(err.Error(), "连接") || strings.Contains(err.Error(), "timeout") {
			t.Skipf("网络不可达: %v", err)
		}
		t.Fatalf("目录失败: %v", err)
	}
	if len(chapters) == 0 {
		t.Fatal("目录为空：`<js>…</js>li a` 接力失效？")
	}
	if chapters[0].Title == "" || chapters[0].Url == "" {
		t.Fatalf("章节字段缺失: %+v", chapters[0])
	}
	t.Logf("书=%s 章节数=%d 第一章=%s", book.Name, len(chapters), chapters[0].Title)
}

var _ = debug.Enabled // 保持 debug 依赖便于临时排查时打开
