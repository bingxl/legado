package webbook_test

// 用 testdata/sources 里的**真实书源**做的端到端测试。
//
// 三层：
//  1. 回放测试（默认跑）：真实书源 + 真实规则 + 录制的线上快照，断言精确到书名/章节数/正文特征。
//  2. 在线测试（LEGADO_ONLINE=1）：直连站点，只断言结构性不变量（数量>0、字段非空）。
//  3. 规则语义测试（离线）：对无法访问的站点，用合成 HTML 验证规则本身可解析。
//
// 重新录制快照：
//
//	LEGADO_RECORD=1 go test ./pkg/webbook -run 'TestSourceManhuaReplay|TestSourceLangrenReplay'

import (
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/download"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/rule"
	"github.com/legado/legado-go/pkg/webbook"
)

// —— 漫画客：JSON 接口搜索 + JS 生成目录 + base64/XOR 正文 ——

func TestSourceManhuaReplay(t *testing.T) {
	useVCR(t, "manhua")
	src := loadSource(t, "yumanhua_comic_source.json", "漫画客")

	// 1. 搜索（POST + JSON 响应 + `$.data` 列表规则 + `/{{$.id}}/` 详情地址模板）
	list, err := webbook.SearchBook(src, "海贼", 1)
	if err != nil {
		t.Fatalf("搜索失败: %v", err)
	}
	if len(list) != 9 {
		t.Fatalf("搜索结果数量错误: 期望 9，实际 %d", len(list))
	}
	if list[0].Name != "海贼王" {
		t.Errorf("首条书名错误: %q", list[0].Name)
	}
	// 该接口没有 author 字段，`$.author` 取不到是正常的；这里校验 remarks 字段
	if list[0].LatestChapterTitle != "第1196话" {
		t.Errorf("首条最新话错误: %q", list[0].LatestChapterTitle)
	}
	if !strings.HasSuffix(list[0].BookUrl, "/GZxNZae/") {
		t.Errorf("详情地址错误: %q", list[0].BookUrl)
	}

	// 2. 发现（exploreUrl 的三行 `分类::地址,{method:POST,body:...}` 写法）
	explore, err := webbook.ExploreBook(src, "", 1)
	if err != nil {
		t.Fatalf("发现失败: %v", err)
	}
	if len(explore) != 20 {
		t.Fatalf("发现数量错误: 期望 20，实际 %d", len(explore))
	}
	if explore[0].Name != "我行让我来" {
		t.Errorf("发现首条书名错误: %q", explore[0].Name)
	}

	// 3. 详情
	book := list[0].ToBook()
	if err := webbook.GetBookInfo(src, book); err != nil {
		t.Fatalf("详情失败: %v", err)
	}
	for _, c := range []struct{ field, want string }{
		{"书名", book.Name},
		{"作者", book.Author},
		{"分类", book.Kind},
		{"最新", book.LatestChapterTitle},
	} {
		if c.want == "" {
			t.Errorf("%s 为空", c.field)
		}
	}
	if book.Name != "海贼王" || book.Author != "尾田荣一郎" {
		t.Errorf("详情内容错误: name=%q author=%q", book.Name, book.Author)
	}
	if !strings.Contains(book.Kind, "冒险") || !strings.Contains(book.Kind, "热血") {
		t.Errorf("分类错误: %q", book.Kind)
	}
	if !strings.HasPrefix(book.CoverUrl, "https://") {
		t.Errorf("封面地址错误: %q", book.CoverUrl)
	}
	if !strings.Contains(book.Intro, "路飞") {
		t.Errorf("简介异常: %.40q", book.Intro)
	}

	// 4. 目录（规则是一大段 JS：从页面里抠 baseUrl 的书籍 id 再解析列表）
	chapters, err := webbook.GetChapterList(src, book, false)
	if err != nil {
		t.Fatalf("目录失败: %v", err)
	}
	if len(chapters) != 1201 {
		t.Fatalf("章节数错误: 期望 1201，实际 %d", len(chapters))
	}
	if chapters[0].Title != "番外1 草帽剧场:海的音乐会" {
		t.Errorf("首章标题错误: %q", chapters[0].Title)
	}
	if chapters[1].Title != "第1话 ROMANCE DAWN" {
		t.Errorf("第 2 章标题错误: %q", chapters[1].Title)
	}
	if !strings.HasSuffix(chapters[1].Url, ".html") {
		t.Errorf("章节地址格式异常: %q", chapters[1].Url)
	}
	// 目录规则产出的是相对地址，靠 BaseUrl 绝对化（legado 行为一致）
	if abs := chapters[1].GetAbsoluteURL(); !strings.HasPrefix(abs, "http://yumanhua.com/") {
		t.Errorf("章节地址未绝对化: url=%q baseUrl=%q abs=%q", chapters[1].Url, chapters[1].BaseUrl, abs)
	}

	// 5. 正文（JS 解 base64 + XOR 还原图片地址）
	content, err := webbook.GetContent(src, book, chapters[1], "")
	if err != nil {
		t.Fatalf("正文失败: %v", err)
	}
	if !strings.Contains(content, "<img") {
		t.Fatalf("正文应包含图片标签: %.80q", content)
	}
	imgs := download.ExtractImages(content)
	if len(imgs) < 10 {
		t.Fatalf("图片数量异常: %d", len(imgs))
	}
	for _, u := range imgs[:3] {
		if !strings.HasPrefix(u, "https://") || !strings.Contains(u, "~tplv-") {
			t.Errorf("图片地址异常: %q", u)
		}
	}
	t.Logf("漫画客：搜索 %d / 发现 %d / 目录 %d 章 / 首章 %d 张图",
		len(list), len(explore), len(chapters), len(imgs))
}

// —— 狼人小说：GBK 搜索地址 + 旧式索引（dt.0 / tag.a.0）+ 链式 @html@js 清洗 ——

func TestSourceLangrenReplay(t *testing.T) {
	useVCR(t, "langren")
	src := loadSource(t, "t66y_book_source.json", "狼人小说")

	// 1. 搜索：POST + `{"charset":"gbk"}`
	//    两个回归点：① 表单要按 GBK 编码（GBK 站点收到 UTF-8 字节会 0 结果）
	//               ② `@css:...>li:gt(0)` 的 jsoup 索引伪类要能跳过表头行
	list, err := webbook.SearchBook(src, "监禁", 1)
	if err != nil {
		t.Fatalf("搜索失败: %v", err)
	}
	if len(list) != 3 {
		t.Fatalf("搜索结果数量错误: 期望 3，实际 %d", len(list))
	}
	if list[0].Name != "监禁幻想" {
		t.Errorf("搜索首条书名错误: %q", list[0].Name)
	}
	if list[0].Author != "女王刹那雪的小弟" {
		t.Errorf("搜索首条作者错误: %q", list[0].Author)
	}
	if !strings.HasPrefix(list[0].BookUrl, "https://www.langrenxiaoshuo.com/html/") {
		t.Errorf("搜索首条详情地址错误: %q", list[0].BookUrl)
	}

	// 2. 发现：exploreUrl 是 JSON 数组，且地址里带 `{{page === 1 ? '' : ...}}`
	explore, err := webbook.ExploreBook(src, "", 1)
	if err != nil {
		t.Fatalf("发现失败: %v", err)
	}
	if len(explore) != 30 {
		t.Fatalf("发现数量错误: 期望 30，实际 %d", len(explore))
	}
	// 断言语义是「发现页首条能正确解析出书名/作者」，具体值随站点更新而变化，
	// 重录快照时同步更新。
	if explore[0].Name != "按摩的升级欲望" {
		t.Errorf("发现首条书名错误: %q", explore[0].Name)
	}
	if explore[0].Author != "Yulu" {
		t.Errorf("发现首条作者错误: %q", explore[0].Author)
	}
	// `bookUrl: tag.a.0@href` 旧式索引
	if !strings.HasPrefix(explore[0].BookUrl, "https://www.langrenxiaoshuo.com/html/") {
		t.Errorf("发现首条详情地址错误: %q", explore[0].BookUrl)
	}

	// 3. 详情
	book := model.NewBook()
	book.BookUrl = "https://www.langrenxiaoshuo.com/html/jianjinwang/"
	book.Origin = src.BookSourceUrl
	if err := webbook.GetBookInfo(src, book); err != nil {
		t.Fatalf("详情失败: %v", err)
	}
	if book.TocUrl != book.BookUrl {
		t.Errorf("目录地址错误: %q", book.TocUrl)
	}
	if !strings.Contains(book.Author, "マサイ") {
		t.Errorf("作者字段异常: %q", book.Author)
	}
	if !strings.Contains(book.Intro, "恶魔") {
		t.Errorf("简介异常: %.40q", book.Intro)
	}

	// 4. 目录：chapterName 是单段 `text`，chapterUrl 是单段 `href`（属性名写法）
	chapters, err := webbook.GetChapterList(src, book, false)
	if err != nil {
		t.Fatalf("目录失败: %v", err)
	}
	// 章节数随站点连裁增长，重录快照时同步更新。
	if len(chapters) != 73 {
		t.Fatalf("章节数错误: 期望 73，实际 %d", len(chapters))
	}
	if chapters[0].Title != "【监禁王】（第一章1-4）" {
		t.Errorf("首章标题错误: %q", chapters[0].Title)
	}
	// 回归：`chapterUrl: "href"` 必须取到 <a> 的属性，而不是回退成书籍地址
	if chapters[0].Url == book.BookUrl {
		t.Fatalf("章节地址错误地等于书籍地址（单段属性名规则失效）: %q", chapters[0].Url)
	}
	if !strings.HasSuffix(chapters[0].Url, ".html") {
		t.Errorf("章节地址格式异常: %q", chapters[0].Url)
	}

	// 5. 正文：`#content div@html@js:清洗` 的链式规则
	content, err := webbook.GetContent(src, book, chapters[0], "")
	if err != nil {
		t.Fatalf("正文失败: %v", err)
	}
	if len(content) < 1000 {
		t.Fatalf("正文过短: %d", len(content))
	}
	// 正文首段是简介与章节标题，正文人物名应出现
	if !strings.Contains(content, "文雄") {
		t.Errorf("正文内容异常: %.60q", content)
	}
	for _, bad := range []string{"<font", "<center", "<script", "<!--"} {
		if strings.Contains(content, bad) {
			t.Errorf("正文未清洗干净，仍含 %q", bad)
		}
	}
	t.Logf("狼人小说：搜索 %d / 发现 %d / 目录 %d 章 / 首章 %d 字",
		len(list), len(explore), len(chapters), len([]rune(content)))
}

// —— t66y（草榴社區 · 成人文學交流區）：离线规则语义校验 ——
//
// 该源的形态是「一个帖子 = 一本书 = 一章」：目录规则直接返回单章，正文就是楼主帖。
// 站点在境内常被墙，CI 里只跑离线规则（真站链路靠 LEGADO_ONLINE 手工验）。

func TestSourceT66yRulesOffline(t *testing.T) {
	src := loadSource(t, "t66y_book_source.json", "t66y")

	if src.SearchUrl != "" {
		t.Errorf("该源只有发现，searchUrl 应为空: %q", src.SearchUrl)
	}

	// 列表页结构（按站点真实 DOM 精简）：#tbody > tr > td.tal > h3 > a
	const listHTML = `<html><body><table><tbody id="tbody">
	<tr class="tr3 t_one tac"><td class="tal" id="">
	[現代奇幻]
	<h3><a href="/htm_data/2611/20/7505912.html" target="_blank" id="t7505912">偷吃老爸好几次（共12章）</a></h3>
	</td><td><a href="/thread0806.php?fid=20&search=1" class="bl">link1568</a></td></tr>
	</tbody></table></body></html>`

	ar := rule.New(src)
	ar.SetContent(listHTML, src.BookSourceUrl)
	els := ar.GetElements(src.GetExploreRule().BookList)
	if len(els) != 1 {
		t.Fatalf("列表规则未命中: %d", len(els))
	}

	item := rule.New(src)
	item.SetContent(els[0])
	if got := item.GetString(src.GetExploreRule().Name); got != "偷吃老爸好几次（共12章）" {
		t.Errorf("name 规则结果错误: %q", got)
	}

	// ★ 回归点：bookUrl 的 ## 替换必须**吃掉整段路径**。
	// 曾经写成 `href##(\d+)\.html##/read.php?tid=$1&toread=2`，只替换了文件名，
	// 产出 /htm_data/2611/20//read.php?tid=7505912 —— 站点对该地址返回 404
	// （「無法找到頁面」，不含 div.tpc_content），现场表现就是「正文页解析结果为空」。
	got := item.GetString(src.GetExploreRule().BookUrl)
	if want := "/read.php?tid=7505912&toread=2"; got != want {
		t.Fatalf("bookUrl 规则结果错误: %q（期望 %q）", got, want)
	}
	if strings.Contains(got, "htm_data") {
		t.Errorf("bookUrl 残留 htm_data 路径，会 404: %q", got)
	}

	// 详情页：<title> 带 [分類] 前缀与站点后缀，规则要剥干净
	const infoHTML = `<html><head><title>[另類禁忌] 偷吃老爸好几次（共12章） - 成人文學交流區 | 草榴社區 - t66y.com</title></head>
	<body><div class="tpc_content" id="conttpc">作者：lili525<br /><br />　　（一）<br />　　第一段正文</div></body></html>`
	const pageURL = "https://t66y.com/read.php?tid=7505912&toread=2"

	ir := rule.New(src)
	ir.SetContent(infoHTML, pageURL)
	if got := ir.GetString(src.GetBookInfoRule().Name); got != "偷吃老爸好几次（共12章）" {
		t.Errorf("详情 name 规则结果错误: %q", got)
	}
	if got := ir.GetString(src.GetBookInfoRule().Author); got != "lili525" {
		t.Errorf("详情 author 规则结果错误: %q", got)
	}

	// 目录：单帖单章（chapterList 命中 body 一个元素）
	tr := rule.New(src)
	tr.SetContent(infoHTML, pageURL)
	if els := tr.GetElements(src.GetTocRule().ChapterList); len(els) != 1 {
		t.Errorf("chapterList 规则应返回 1 个元素，实际 %d", len(els))
	}

	// 正文：div.tpc_content@html（保留 <br>，比 @textNodes 更利于分段渲染）
	cr := rule.New(src)
	cr.SetContent(infoHTML, pageURL)
	content := cr.GetString(src.GetContentRule().Content)
	for _, want := range []string{"tpc_content", "第一段正文", "<br"} {
		if !strings.Contains(content, want) {
			t.Errorf("正文规则结果缺少 %q: %.120q", want, content)
		}
	}
	if strings.Contains(content, "script") {
		t.Errorf("正文未清洗 script: %.120q", content)
	}
}

// —— 爱丽丝书屋（alicesw.com）：站点在境内不可达，只做离线的规则语义校验 ——
//
// 该源是纯静态 HTML：列表 / 详情 / 目录 / 正文全部服务端直出，没有任何 JS 计算或接口二次请求。
// 需要代理才能访问真站，所以 CI 只跑离线规则（真站链路 ALICESW_LIVE=1 手工验）。

func TestSourceAliceSWRulesOffline(t *testing.T) {
	src := loadSource(t, "alicesw_book_source.json", "爱丽丝书屋")

	// 只有发现，没有搜索以外的聚合能力；搜索走 GET 查询串
	if !strings.Contains(src.SearchUrl, "/search.html?q={{key}}") {
		t.Errorf("搜索地址异常: %q", src.SearchUrl)
	}
	kinds := model.ParseExploreKinds(src.ExploreUrl)
	if len(kinds) < 30 || kinds[0].Title != "科幻" || kinds[0].Url != "/lists/71.html?page={{page}}" {
		t.Errorf("发现分类异常（首个 %+v，共 %d 个）", kinds[0], len(kinds))
	}

	// 详情页：作者/分类/最新章靠 div.novel_info 里的 <p> 顺序（p.0/p.1/p.5）
	const detailHTML = `<html><body>
	<div class="detail-cols"><div class="ui_bg6"><div class="box_intro">
	  <div class="pic"><img data-src="https://img.example.com/cover.webp" src="/static/tmp.jpg" alt="测试书"></div>
	  <div class="box_info">
	    <div class="novel_title">测试书名</div>
	    <div class="novel_info">
	      <p>作 者：<a href="/search.html?q=某作者&f=author">某作者</a></p>
	      <p>分 类：<a href="/lists/62.html">玄幻</a></p>
	      <p>热 度：1 · 收 藏：2</p>
	      <p>字 数：1.23万 · 章 节：2</p>
	      <p>状 态：连载中</p>
	      <p>最 新：<a href="/book/50000/abcdef1234567.html">2 第二章</a></p>
	    </div>
	  </div>
	</div>
	<div class="book_newchap">
	  <div class="tit tabtitle">最新章节：全2章 <a href="/other/chapters/id/40000.html">查看所有章节</a></div>
	  <div class="con"><li><a href="/book/50000/abcdef1234567.html">2 第二章</a><em>更新时间：2026-11-09 01:47</em></li></div>
	</div>
	<div class="jianjie"><h6>内容简介：</h6><p>这里是简介正文。</p><div id="ddlist">随机提示</div></div>
	</div></div></body></html>`
	const detailURL = "https://www.alicesw.com/novel/40000.html"

	ir := rule.New(src)
	ir.SetContent(detailHTML, detailURL)
	info := src.GetBookInfoRule()
	checks := map[string]string{
		"name":        "测试书名",
		"author":      "某作者",
		"kind":        "玄幻",
		"lastChapter": "2 第二章",
		"coverUrl":    "https://img.example.com/cover.webp",
		"intro":       "这里是简介正文。",
	}
	got := map[string]string{
		"name":        ir.GetString(info.Name),
		"author":      ir.GetString(info.Author),
		"kind":        ir.GetString(info.Kind),
		"lastChapter": ir.GetString(info.LastChapter),
		"coverUrl":    ir.GetString(info.CoverUrl),
		"intro":       ir.GetString(info.Intro),
	}
	for k, want := range checks {
		if got[k] != want {
			t.Errorf("详情 %s 规则结果错误: %q（期望 %q）", k, got[k], want)
		}
	}

	// ★ 回归点：tocUrl 必须取详情页里「查看所有章节」的链接。
	// 详情 ID(40000) 与章节页 ID(50000) 不是同一个数字，用详情 URL 拼 /book/<id>/ 一定 404。
	if u := ir.GetString(info.TocUrl); u != "/other/chapters/id/40000.html" {
		t.Fatalf("tocUrl 规则结果错误: %q", u)
	}

	// 目录：ul.mulu_list 一次给全（站点不分页）
	const tocHTML = `<html><body><ul class="mulu_list">
	<li><a href="/book/50000/9f25147eca9f8.html" target="_blank">1 第一章</a></li>
	<li><a href="/book/50000/abcdef1234567.html" target="_blank">2 第二章</a></li>
	</ul></body></html>`
	tr := rule.New(src)
	tr.SetContent(tocHTML, "https://www.alicesw.com/other/chapters/id/40000.html")
	els := tr.GetElements(src.GetTocRule().ChapterList)
	if len(els) != 2 {
		t.Fatalf("目录规则应返回 2 章，实际 %d", len(els))
	}
	cr0 := rule.New(src)
	cr0.SetContent(els[1])
	if n, u := cr0.GetString(src.GetTocRule().ChapterName), cr0.GetString(src.GetTocRule().ChapterUrl); n != "2 第二章" || u != "/book/50000/abcdef1234567.html" {
		t.Errorf("章节规则结果错误: %q %q", n, u)
	}

	// 正文：div.read-content 内是 <p> 段落，@html 保留分段
	const chapHTML = `<html><body><div class="read-content j_readContent user_ad_content">
	<p>　　第一段正文。</p><p>　　第二段正文。</p>
	</div><div id="user_ad"></div></body></html>`
	ch := rule.New(src)
	ch.SetContent(chapHTML, "https://www.alicesw.com/book/50000/abcdef1234567.html")
	content := ch.GetString(src.GetContentRule().Content)
	for _, want := range []string{"第一段正文", "第二段正文", "<p>"} {
		if !strings.Contains(content, want) {
			t.Errorf("正文规则结果缺少 %q: %.120q", want, content)
		}
	}
	if strings.Contains(content, `id="user_ad"`) {
		t.Errorf("正文误吞广告区: %.120q", content)
	}

	// 发现列表：div.rec_rullist 下每个 <ul> 是一条
	const listHTML = `<html><body><div class="clearfix rec_rullist"><ul>
	<li class="one"><span>1</span></li>
	<li class="sev"><span><a href="/lists/62.html">玄幻小说</a></span></li>
	<li class="two"><a href="/novel/54028.html" target="_blank">玉壶修仙传</a></li>
	<li class="three"><a href="/book/55360/e15a23a5fa4d3.html">02 夜半杀人</a></li>
	<li class="four">某作者</li><li class="five">0.77万</li><li class="six">2026-11-09</li>
	</ul></div></body></html>`
	lr := rule.New(src)
	lr.SetContent(listHTML, "https://www.alicesw.com/lists/62.html?page=1")
	els = lr.GetElements(src.GetExploreRule().BookList)
	if len(els) != 1 {
		t.Fatalf("发现列表规则未命中: %d", len(els))
	}
	er := rule.New(src)
	er.SetContent(els[0])
	xr := src.GetExploreRule()
	if v := er.GetString(xr.Name); v != "玉壶修仙传" {
		t.Errorf("发现 name 错误: %q", v)
	}
	if v := er.GetString(xr.Author); v != "某作者" {
		t.Errorf("发现 author 错误: %q", v)
	}
	if v := er.GetString(xr.Kind); v != "玄幻" {
		t.Errorf("发现 kind 应剥掉「小说」后缀: %q", v)
	}
	if v := er.GetString(xr.LastChapter); v != "02 夜半杀人" {
		t.Errorf("发现 lastChapter 错误: %q", v)
	}
	if v := er.GetString(xr.BookUrl); v != "/novel/54028.html" {
		t.Errorf("发现 bookUrl 错误: %q", v)
	}

	// 搜索：div.list-group-item，书名带「1. 」序号前缀要剥掉，标签要去 # 并逗号连接
	const searchHTML = `<html><body><div class="list-group">
	<div class="list-group-item">
	  <h5><a href="/novel/42159.html" target="_blank">1. 逸<em>剑</em>风云决</a><small>[已完结]</small></h5>
	  <p class="mb-1 text-muted">作者：<a href="/search?q=Ding&f=author">Ding</a> 字数：2.47万</p>
	  <p class="content-txt">简介首句。</p>
	  <p class="text-muted">标签：<a href="/search?q=x&f=tag"><span>#</span>调教</a> <a href="/search?q=y&f=tag"><span>#</span>凌辱</a></p>
	  <p class="timedesc">发布时间：2025-07-26</p>
	</div></div></body></html>`
	sr := rule.New(src)
	sr.SetContent(searchHTML, "https://www.alicesw.com/search.html?q=%E5%89%91&f=_all")
	els = sr.GetElements(src.GetSearchRule().BookList)
	if len(els) != 1 {
		t.Fatalf("搜索列表规则未命中: %d", len(els))
	}
	ss := rule.New(src)
	ss.SetContent(els[0])
	xq := src.GetSearchRule()
	if v := ss.GetString(xq.Name); v != "逸剑风云决" {
		t.Errorf("搜索 name 应剥掉序号前缀: %q", v)
	}
	if v := ss.GetString(xq.Author); v != "Ding" {
		t.Errorf("搜索 author 错误: %q", v)
	}
	if v := ss.GetString(xq.Intro); v != "简介首句。" {
		t.Errorf("搜索 intro 错误: %q", v)
	}
	if v := ss.GetString(xq.Kind); v != "调教,凌辱" {
		t.Errorf("搜索 kind 应为「调教,凌辱」: %q", v)
	}
	if v := ss.GetString(xq.BookUrl); v != "/novel/42159.html" {
		t.Errorf("搜索 bookUrl 错误: %q", v)
	}

	// bookUrlPattern 只认详情页，别把列表/搜索/章节页当成书
	if !regexp.MustCompile(src.BookUrlPattern).MatchString(detailURL) {
		t.Errorf("bookUrlPattern 未命中详情页: %s", src.BookUrlPattern)
	}
	for _, u := range []string{
		"https://www.alicesw.com/lists/62.html",
		"https://www.alicesw.com/search.html?q=a&f=_all",
		"https://www.alicesw.com/book/50000/abcdef1234567.html",
	} {
		if regexp.MustCompile(src.BookUrlPattern).MatchString(u) {
			t.Errorf("bookUrlPattern 误命中非详情页: %s", u)
		}
	}
}

// —— 下载：真实书源 + 真实章节，导出 txt（回放快照，含并发抓取） ——

func TestSourceLangrenDownload(t *testing.T) {
	useVCR(t, "langren_download")
	src := loadSource(t, "t66y_book_source.json", "狼人小说")

	book := model.NewBook()
	book.BookUrl = "https://www.langrenxiaoshuo.com/html/jianjinwang/"
	book.Origin = src.BookSourceUrl

	dir := t.TempDir()
	res, err := download.DownloadBook(src, book, download.Options{
		OutDir:  dir,
		Format:  "txt",
		Workers: 3,
		Max:     3,
	})
	if err != nil {
		t.Fatalf("下载失败: %v", err)
	}
	if res.Chapters != 3 {
		t.Fatalf("下载章节数错误: 期望 3，实际 %d", res.Chapters)
	}
	if len(res.Failed) != 0 {
		t.Fatalf("存在失败章节: %v", res.Failed)
	}
	data, err := os.ReadFile(res.Path)
	if err != nil {
		t.Fatalf("读取产物失败: %v", err)
	}
	text := string(data)
	for _, want := range []string{"【监禁王】（第一章1-4）", "【监禁王】（第一章5-8）", "文雄"} {
		if !strings.Contains(text, want) {
			t.Errorf("产物缺少 %q", want)
		}
	}
	if strings.Contains(text, "<font") || strings.Contains(text, "<center") {
		t.Errorf("产物未清洗干净")
	}
	t.Logf("下载 OK: %s（%d 章，%d 字节）", res.Path, res.Chapters, len(data))
}

// —— 在线测试：默认跳过，LEGADO_ONLINE=1 时直连站点 ——

func TestSourceOnlineLive(t *testing.T) {
	if os.Getenv("LEGADO_ONLINE") != "1" {
		t.Skip("在线测试默认跳过，设置 LEGADO_ONLINE=1 开启")
	}
	cases := []struct {
		file, name, book string
		wantChapters     int // 0 表示不断言精确章节数
	}{
		{"yumanhua_comic_source.json", "漫画客", "http://yumanhua.com/GZxNZae/", 1201},
		{"t66y_book_source.json", "狼人小说", "https://www.langrenxiaoshuo.com/html/jianjinwang/", 70},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			src := loadSource(t, c.file, c.name)
			book := model.NewBook()
			book.BookUrl = c.book
			book.Origin = src.BookSourceUrl
			if err := webbook.GetBookInfo(src, book); err != nil {
				t.Skipf("站点不可达或已变更: %v", err)
			}
			if book.Name == "" {
				t.Errorf("书名解析为空")
			}
			chapters, err := webbook.GetChapterList(src, book, false)
			if err != nil {
				t.Fatalf("目录失败: %v", err)
			}
			if len(chapters) == 0 {
				t.Fatalf("目录为空")
			}
			if c.wantChapters > 0 && len(chapters) != c.wantChapters {
				t.Errorf("章节数变化: 期望 %d，实际 %d（站点或书源可能已更新）", c.wantChapters, len(chapters))
			}
			content, err := webbook.GetContent(src, book, chapters[0], "")
			if err != nil {
				t.Fatalf("正文失败: %v", err)
			}
			if len(content) < 100 {
				t.Errorf("正文过短: %d", len(content))
			}
			t.Logf("%s 在线：%s / %d 章 / 首章 %d 字", c.name, book.Name, len(chapters), len([]rune(content)))
		})
	}
}
