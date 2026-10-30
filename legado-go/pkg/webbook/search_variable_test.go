package webbook

import (
	"encoding/json"
	"testing"

	"github.com/legado/legado-go/pkg/model"
)

// 回归：@put 必须落在「当前这一条搜索结果」自己的变量表上。
//
// 修复前 getSearchItem 复用同一个绑定在共享 RuleData 上的 AnalyzeRule，
// 同一页的多条结果会互相覆盖（后一条盖掉前一条），变量也从来没进
// SearchBook.VariableHolder，导致目录/正文规则里的 @get 取不到值
// （真实案例：17k小说 的 tocUrl ".../book/@get:{book}/volumes" 拼出 book//volumes）。
func TestSearchPutVariablePerItem(t *testing.T) {
	srv := newRulesServer(t, map[string]string{
		"/search": `<html><body><ul id="list">
			<li><span class="id">101</span><a class="n" href="/b/101">书名一</a></li>
			<li><span class="id">202</span><a class="n" href="/b/202">书名二</a></li>
		</ul></body></html>`,
		"/b/101": `<html><body><h1>书名一</h1></body></html>`,
	})
	src := &model.BookSource{
		BookSourceUrl:  srv.URL,
		BookSourceName: "put-test",
		SearchUrl:      srv.URL + "/search?key={{key}}",
		RuleSearch: &model.SearchRule{
			BookList: "@css:#list li",
			Name:     `@css:a.n@text@put:{bid:@css:span.id@text}`,
			BookUrl:  "@css:a.n@href",
		},
		// 真实的 17k 形态：目录地址里用 @get 拼搜索阶段的 @put 变量
		RuleBookInfo: &model.BookInfoRule{
			Name:   "@css:h1@text",
			TocUrl: srv.URL + `/book/@get:{bid}/volumes`,
		},
	}

	list, err := SearchBook(src, "书", 1)
	if err != nil {
		t.Fatalf("SearchBook 出错: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("应解析出 2 条结果，实际 %d 条", len(list))
	}

	want := []string{"101", "202"}
	for i, sb := range list {
		if got := sb.GetVariable("bid"); got != want[i] {
			t.Fatalf("第 %d 条的 @put 变量应为 %q，实际 %q（变量表被共享/覆盖）", i+1, want[i], got)
		}
		// Variable 是跨模块传递变量用的 JSON 字段，必须同步。
		vars := map[string]string{}
		if err := json.Unmarshal([]byte(sb.Variable), &vars); err != nil {
			t.Fatalf("第 %d 条 Variable 不是合法 JSON: %q", i+1, sb.Variable)
		}
		if vars["bid"] != want[i] {
			t.Fatalf("第 %d 条 Variable 中 bid 应为 %q，实际 %q", i+1, want[i], vars["bid"])
		}
	}

	// 变量要随 ToBook 进入书架书籍，否则目录/正文阶段的 @get 取不到。
	book := list[0].ToBook()
	if got := book.GetVariable("bid"); got != "101" {
		t.Fatalf("ToBook 后变量丢失: %q", got)
	}
	// 目录规则用 @get 取变量的真实路径：tocUrl 里内嵌 @get:{bid}
	if err := GetBookInfo(src, book); err != nil {
		t.Fatalf("GetBookInfo 出错: %v", err)
	}
	if want := srv.URL + "/book/101/volumes"; book.TocUrl != want {
		t.Fatalf("tocUrl 应拼入 @put 变量 %q，实际 %q", want, book.TocUrl)
	}
}

// 没有 @put 的书源不该凭空生出变变量字段，避免污染搜索结果 JSON。
func TestSearchWithoutPutHasNoVariable(t *testing.T) {
	srv := newRulesServer(t, map[string]string{
		"/search": `<html><body><ul id="list">
			<li><a class="n" href="/b/1">书名一</a></li>
		</ul></body></html>`,
	})
	src := &model.BookSource{
		BookSourceUrl:  srv.URL,
		BookSourceName: "plain-test",
		SearchUrl:      srv.URL + "/search?key={{key}}",
		RuleSearch: &model.SearchRule{
			BookList: "@css:#list li",
			Name:     "@css:a.n@text",
			BookUrl:  "@css:a.n@href",
		},
	}
	list, err := SearchBook(src, "书", 1)
	if err != nil {
		t.Fatalf("SearchBook 出错: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("应解析出 1 条结果，实际 %d 条", len(list))
	}
	if list[0].Variable != "" {
		t.Fatalf("没有 @put 时 Variable 应为空，实际 %q", list[0].Variable)
	}
}
