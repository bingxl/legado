package rule

import (
	"testing"
)

const testHTML = `<html><body>
<div class="book"><h3><a href="/b/1" id="t1">斗破苍穹</a></h3><span class="au">天蚕土豆</span></div>
<div class="book"><h3><a href="/b/2" id="t2">武动乾坤</a></h3><span class="au">天蚕土豆</span></div>
<ul id="list"><li>第一章</li><li>第二章</li><li>第三章</li></ul>
<p>第一段 &amp; 第二段</p>
</body></html>`

const testJSON = `{"store":{"book":[{"title":"书A","price":8.9},{"title":"书B","price":12.5}],"name":"我的书店"}}`

func newTestRule(t *testing.T, content string) *AnalyzeRule {
	ar := New(nil)
	ar.SetContent(content, "https://example.com/")
	ar.SetRedirectUrl("https://example.com/")
	return ar
}

func TestJsoupText(t *testing.T) {
	ar := newTestRule(t, testHTML)
	// 规则匹配到 2 个元素：legado 的 getString 对多结果用换行拼接
	if got := ar.GetString("h3 a@text"); got != "斗破苍穹\n武动乾坤" {
		t.Fatalf("期望 斗破苍穹\\n武动乾坤, 得到 %q", got)
	}
	// 用索引取单个
	if got := ar.GetString("h3 a[0]@text"); got != "斗破苍穹" {
		t.Fatalf("索引取值错误: %q", got)
	}
}

func TestJsoupList(t *testing.T) {
	ar := newTestRule(t, testHTML)
	list := ar.GetStringList("h3 a@text")
	if len(list) != 2 || list[0] != "斗破苍穹" || list[1] != "武动乾坤" {
		t.Fatalf("列表解析错误: %#v", list)
	}
}

func TestJsoupAttr(t *testing.T) {
	ar := newTestRule(t, testHTML)
	if got := ar.GetString("h3 a@href"); got != "/b/1\n/b/2" {
		t.Fatalf("属性解析错误: %q", got)
	}
}

func TestJsoupUrl(t *testing.T) {
	ar := newTestRule(t, testHTML)
	if got := ar.GetString("h3 a@href", true); got != "https://example.com/b/1" {
		t.Fatalf("URL 绝对化错误: %q", got)
	}
}

func TestJsoupCssPrefix(t *testing.T) {
	ar := newTestRule(t, testHTML)
	if got := ar.GetString("@CSS:h3 a@text"); got != "斗破苍穹\n武动乾坤" {
		t.Fatalf("@CSS 前缀解析错误: %q", got)
	}
}

func TestJsoupIndex(t *testing.T) {
	ar := newTestRule(t, testHTML)
	// 旧式索引：id 前缀 + @ 分层 + .0 取第一个
	if got := ar.GetString("id.list@tag.li.0@text"); got != "第一章" {
		t.Fatalf("旧式索引解析错误: %q", got)
	}
	// 新式索引：[-1] 取最后一个
	if got := ar.GetString("id.list@tag.li[-1]@text"); got != "第三章" {
		t.Fatalf("负数索引解析错误: %q", got)
	}
	// 区间索引：[0:1] 取前两个
	list := ar.GetStringList("id.list@tag.li[0:1]@text")
	if len(list) != 2 || list[0] != "第一章" || list[1] != "第二章" {
		t.Fatalf("区间索引解析错误: %#v", list)
	}
}

func TestJsoupElements(t *testing.T) {
	ar := newTestRule(t, testHTML)
	els := ar.GetElements("div.book")
	if len(els) != 2 {
		t.Fatalf("元素数量错误: %d", len(els))
	}
	ar.SetContent(els[0])
	if got := ar.GetString("h3 a@text"); got != "斗破苍穹" {
		t.Fatalf("子元素解析错误: %q", got)
	}
}

func TestJsoupHtmlAndTextNodes(t *testing.T) {
	ar := newTestRule(t, testHTML)
	if got := ar.GetString("p@html"); got == "" {
		t.Fatal("html 取值不应为空")
	}
	if got := ar.GetString("p@textNodes"); got != "第一段 & 第二段" {
		t.Fatalf("textNodes 解析错误: %q", got)
	}
}

func TestUnescape(t *testing.T) {
	ar := newTestRule(t, testHTML)
	got := ar.GetString("p@text")
	if got != "第一段 & 第二段" {
		t.Fatalf("HTML 反转义错误: %q", got)
	}
}

func TestJsonPath(t *testing.T) {
	ar := newTestRule(t, testJSON)
	if got := ar.GetString("$.store.name"); got != "我的书店" {
		t.Fatalf("JSONPath 取值错误: %q", got)
	}
	if got := ar.GetString("$.store.book[0].title"); got != "书A" {
		t.Fatalf("JSONPath 数组取值错误: %q", got)
	}
	list := ar.GetStringList("$.store.book[*].title")
	if len(list) != 2 {
		t.Fatalf("JSONPath 列表错误: %#v", list)
	}
}

func TestJsonAutoDetect(t *testing.T) {
	ar := newTestRule(t, testJSON)
	// 内容为 JSON 时，无前缀规则默认走 Json 模式
	if got := ar.GetString("$.store.book[1].title"); got != "书B" {
		t.Fatalf("JSON 自动识别错误: %q", got)
	}
}

func TestXPath(t *testing.T) {
	ar := newTestRule(t, testHTML)
	list := ar.GetStringList("//h3/a")
	if len(list) != 2 || list[0] != "斗破苍穹" {
		t.Fatalf("XPath 解析错误: %#v", list)
	}
}

func TestRegexRule(t *testing.T) {
	// allInOne 正则：getElements 以 : 开头时整体按正则处理
	ar := newTestRule(t, "编号ABC123结束")
	els := ar.GetElements(":编号(\\w+)结束")
	if len(els) != 1 {
		t.Fatalf("正则提取失败: %#v", els)
	}
	groups, ok := els[0].([]string)
	if !ok || len(groups) < 2 {
		t.Fatalf("正则分组错误: %#v", els[0])
	}
	if groups[0] != "编号ABC123结束" || groups[1] != "ABC123" {
		t.Fatalf("正则分组内容错误: %#v", groups)
	}
}

func TestRegexMultiLevel(t *testing.T) {
	ar := newTestRule(t, "<li>A</li><li>B</li>")
	els := ar.GetElements(":<li>(.*?)</li>&&<li>(.*?)</li>")
	t.Logf("多级正则结果: %#v", els)
}

func TestReplaceRegex(t *testing.T) {
	ar := newTestRule(t, testHTML)
	got := ar.GetString("h3 a@text##斗破##星辰")
	if got != "星辰苍穹\n武动乾坤" {
		t.Fatalf("## 替换错误: %q", got)
	}
}

func TestJS(t *testing.T) {
	ar := newTestRule(t, testHTML)
	if got := ar.GetString("@js:'前缀-'+result"); got != "" {
		t.Logf("@js 结果: %q", got)
	}
	ar2 := newTestRule(t, testHTML)
	if got := ar2.GetString("<js>'a'+'</js>"); got != "" && got != "a" {
		t.Fatalf("<js> 解析错误: %q", got)
	}
}

func TestJSWithResult(t *testing.T) {
	ar := newTestRule(t, testHTML)
	got := ar.GetString("@js:result.select('h3 a').text()")
	t.Logf("JS select 结果: %q", got)
	_ = got
}

func TestPutGet(t *testing.T) {
	ar := newTestRule(t, testHTML)
	ar.Put("mykey", "myvalue")
	if got := ar.Get("mykey"); got != "myvalue" {
		t.Fatalf("变量存取错误: %q", got)
	}
	// @put 规则：值按规则求值后存入变量
	ar2 := newTestRule(t, testHTML)
	got := ar2.GetString("@put:{\"k\":\"h3 a@text\"}h3 a@text")
	if got != "斗破苍穹\n武动乾坤" {
		t.Fatalf("@put 规则解析错误: %q", got)
	}
	if v := ar2.Get("k"); v != "斗破苍穹\n武动乾坤" {
		t.Fatalf("@put 变量未写入: %q", v)
	}
	// @get 规则
	ar2.Put("kk", "VV")
	if got := ar2.GetString("@get:{kk}"); got != "VV" {
		t.Fatalf("@get 规则解析错误: %q", got)
	}
}

func TestInnerJS(t *testing.T) {
	ar := newTestRule(t, testHTML)
	got := ar.GetString("h3 a@text##^.{2}##{{'插'}}")
	t.Logf("内嵌 {{}} 结果: %q", got)
}

func TestSplitCombinator(t *testing.T) {
	typ, parts := SplitCombinator("a&&b&&c", "&&", "||", "%%")
	if typ != "&&" || len(parts) != 3 {
		t.Fatalf("组合符切分错误: %q %#v", typ, parts)
	}
	typ2, parts2 := SplitCombinator("div.a[href='x&&y']@text", "&&", "||", "%%")
	if typ2 != "" || len(parts2) != 1 {
		t.Fatalf("括号内不应被切分: %q %#v", typ2, parts2)
	}
}

func TestSplitTopLevel(t *testing.T) {
	parts := SplitTopLevel("div.book@h3 a@text", "@")
	if len(parts) != 3 || parts[0] != "div.book" || parts[2] != "text" {
		t.Fatalf("@ 切分错误: %#v", parts)
	}
}

func TestGetElementsJson(t *testing.T) {
	ar := newTestRule(t, testJSON)
	els := ar.GetElements("$.store.book")
	if len(els) != 2 {
		t.Fatalf("JSON 列表元素数量错误: %d", len(els))
	}
	ar.SetContent(els[0])
	if got := ar.GetString("$.title"); got != "书A" {
		t.Fatalf("JSON 子元素解析错误: %q", got)
	}
}

// 文档（README / docs/rule-syntax.md）里出现过的写法，逐条验证可用
const docHTML = `<html><body>
<div class="item active"><h3><a href="/1">A</a></h3><span>甲</span></div>
<div class="item"><h3><a href="/2">B</a></h3><span>乙</span></div>
<div class="item"><h3><a href="/3">C</a></h3><span>丙</span></div>
<div>最新章节：<a href="/last">终章</a></div>
</body></html>`

func TestDocExamples(t *testing.T) {
	ar := newTestRule(t, docHTML)

	// 新式索引：排除
	if got := ar.GetStringList("class.item[!0]@tag.a@text"); len(got) != 2 || got[0] != "B" {
		t.Fatalf("[!0] 排除错误: %#v", got)
	}
	// 新式索引：区间
	if got := ar.GetStringList("class.item[0:1]@tag.a@text"); len(got) != 2 {
		t.Fatalf("[0:1] 区间错误: %#v", got)
	}
	// 旧式索引
	if got := ar.GetStringList("class.item!0@tag.a@text"); len(got) != 2 || got[0] != "B" {
		t.Fatalf("旧式 ! 排除错误: %#v", got)
	}
	// text. 选择器
	if got := ar.GetString("text.最新章节"); got == "" {
		t.Fatalf("text. 选择器无结果")
	}
	// && 拼接：各段结果依次追加
	if got := ar.GetStringList("class.active@tag.a@text&&class.item.1@tag.a@text"); len(got) != 2 || got[0] != "A" || got[1] != "B" {
		t.Fatalf("&& 拼接错误: %#v", got)
	}
	// %% 交错
	got := ar.GetStringList("class.item@tag.a@text%%class.item@tag.span@text")
	if len(got) != 6 || got[0] != "A" || got[1] != "甲" {
		t.Fatalf("%% 交错错误: %#v", got)
	}
	// || 短路：第一段非空就不再取后面的
	got2 := ar.GetStringList("class.active@tag.a@text||class.item.1@tag.a@text")
	if len(got2) != 1 || got2[0] != "A" {
		t.Fatalf("|| 短路错误: %#v", got2)
	}
}
