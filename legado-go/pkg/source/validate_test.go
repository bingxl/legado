package source

import (
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/model"
)

// 回归：静态校验不能把「合法的 Java 正则 / legado 变量插值」判成错误。
//
// 这三条规则都取自真实书源（哔哩轻小说、lk轻之国度、轻小说机翻），
// 早先分别误报为「替换正则不合法」「JS 语法错误」「括号未平衡」。
func TestValidate_NoFalsePositivesOnJavaRegexAndMustache(t *testing.T) {
	src := &model.BookSource{
		BookSourceName: "回归样本",
		BookSourceUrl:  "https://example.com",
		SearchUrl:      "/search?q={{key}}&p={{page}}",
		RuleSearch: &model.SearchRule{
			BookList: "class.book-list@tag.li",
			Name:     "tag.a@text",
			BookUrl:  "tag.a@href",
			// JS 里内嵌 {{}} 插值 + 模板字符串
			LastChapter: "@js:\n/\\/wenku\\?/.test(baseUrl) ? '' : `{{$.total}} - ` + new Date(parseInt({{$.updateAt}}) * 1000).toJSON().replace(/T|\\.\\d+Z/gi, ' ')",
		},
		RuleToc: &model.TocRule{
			ChapterList: "id.list@tag.a",
			ChapterName: "text",
			ChapterUrl:  "href",
		},
		RuleContent: &model.ContentRule{
			Content: "id.content@html",
			// Java 环视 + 引号 + 字符类混排
			ReplaceRegex: `##((?<=[\u4e00-\u9fa5“‘「（，])\s+)?<!--\s*\（继续下一页\）\s*-->\s*|`,
		},
	}

	res := Validate(src)
	for _, i := range res.Issues {
		if i.Level == LevelError {
			t.Errorf("不应报错: %s: %s", i.Field, i.Message)
		}
	}
}

// 真错误仍要被抓住：未配对的 {{ }} 与语法错误的 JS。
func TestValidate_CatchesRealErrors(t *testing.T) {
	src := &model.BookSource{
		BookSourceName: "坏源",
		BookSourceUrl:  "https://example.com",
		SearchUrl:      "/search?q={{key",
		RuleSearch: &model.SearchRule{
			BookList: "class.list@tag.li",
			Name:     "@js:\nvar a = ;",
		},
	}
	res := Validate(src)
	var gotMustache, gotJS bool
	for _, i := range res.Issues {
		if strings.Contains(i.Message, "{{ }} 未配对") {
			gotMustache = true
		}
		if strings.Contains(i.Message, "JS 语法错误") {
			gotJS = true
		}
	}
	if !gotMustache {
		t.Error("应检出 {{ }} 未配对")
	}
	if !gotJS {
		t.Error("应检出 JS 语法错误")
	}
}

// 正文探测：前几章为空时应继续往后找，而不是直接判死。
func TestProbeContent_SkipsEmptyLeadingChapters(t *testing.T) {
	if contentProbeLimit < 2 {
		t.Fatalf("探测上限应大于 1，实际 %d", contentProbeLimit)
	}
	if minContentRunes < 10 {
		t.Fatalf("最小字数阈值过低，会放过占位正文：%d", minContentRunes)
	}
}
