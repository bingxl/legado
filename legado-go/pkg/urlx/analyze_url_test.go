package urlx

import "testing"

// 回归：exploreUrl 里常见的分页写法 `/allbook{{page === 1 ? ” : '_15155_' + page}}.html`
// 在 page=1 时必须把整段 {{}} 去掉（狼人小说 exploreUrl）。
func TestReplaceKeyPageJsEmptyResult(t *testing.T) {
	cases := []struct {
		page int
		want string
	}{
		{1, "https://www.langrenxiaoshuo.com/allbook.html"},
		{2, "https://www.langrenxiaoshuo.com/allbook_15155_2.html"},
	}
	for _, c := range cases {
		p := c.page
		au := New(Options{
			Url:     "/allbook{{page === 1 ? '' : '_15155_' + page}}.html",
			Page:    &p,
			BaseUrl: "https://www.langrenxiaoshuo.com",
		})
		if au.URLNoQuery != c.want {
			t.Errorf("page=%d: 期望 %q，实际 %q", c.page, c.want, au.URLNoQuery)
		}
	}
}

// {{key}} 正常替换（搜索地址）
func TestReplaceKeyInUrl(t *testing.T) {
	p := 1
	au := New(Options{
		Url:     "/s?q={{key}}&p={{page}}",
		Key:     "abc",
		Page:    &p,
		BaseUrl: "https://example.com",
	})
	if au.URLNoQuery != "https://example.com/s?q=abc&p=1" {
		t.Errorf("关键词/页码未替换: %q", au.URLNoQuery)
	}
}

// 回归：URL 选项里的 charset 必须真正生效（GBK 站点收 UTF-8 字节会搜不到结果）。
// 对齐 legado AnalyzeUrl.encodeParams：`URLEncoder.encode(value, charset)`。
func TestUrlOptionCharset(t *testing.T) {
	// GET：query 按 GBK 编码
	au := New(Options{
		Url:     "/plus/search.php?q={{key}},{\"charset\":\"gbk\"}",
		Key:     "监禁",
		BaseUrl: "https://www.langrenxiaoshuo.com",
	})
	const wantQuery = "q=%BC%E0%BD%FB"
	if au.EncodedQuery != wantQuery {
		t.Errorf("GET query 未按 GBK 编码: 期望 %q，实际 %q", wantQuery, au.EncodedQuery)
	}
	// 未指定 charset 时保持 UTF-8（不回归既有行为）
	au2 := New(Options{Url: "/s?q={{key}}", Key: "监禁", BaseUrl: "https://example.com"})
	if au2.EncodedQuery != "q=%E7%9B%91%E7%A6%81" {
		t.Errorf("未指定 charset 时应按 UTF-8: %q", au2.EncodedQuery)
	}
	// POST：表单体同样按 GBK 编码
	au3 := New(Options{
		Url:     "/s.php?action=search,{\"method\":\"POST\",\"body\":\"objectType=2&wd={{key}}\",\"charset\":\"gbk\"}",
		Key:     "监禁",
		BaseUrl: "https://www.langrenxiaoshuo.com",
	})
	const wantForm = "objectType=2&wd=%BC%E0%BD%FB"
	if au3.Method != "POST" {
		t.Errorf("method 应为 POST: %q", au3.Method)
	}
	if au3.EncodedForm != wantForm {
		t.Errorf("POST 表单未按 GBK 编码: 期望 %q，实际 %q", wantForm, au3.EncodedForm)
	}
}

// 分页 <1,2,3> 语法
func TestPageListInUrl(t *testing.T) {
	for _, c := range []struct {
		page int
		want string
	}{
		{1, "https://example.com/list/1.html"},
		{2, "https://example.com/list/2.html"},
		{9, "https://example.com/list/3.html"}, // 超出取最后一页
	} {
		p := c.page
		au := New(Options{Url: "/list/<1,2,3>.html", Page: &p, BaseUrl: "https://example.com"})
		if au.URLNoQuery != c.want {
			t.Errorf("page=%d: 期望 %q，实际 %q", c.page, c.want, au.URLNoQuery)
		}
	}
}
