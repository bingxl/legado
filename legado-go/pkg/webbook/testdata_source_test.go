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
	if explore[0].Name != "受全体师生认可赞扬的高冷学生会长" {
		t.Errorf("发现首条书名错误: %q", explore[0].Name)
	}
	if explore[0].Author != "莫良" {
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
	if len(chapters) != 70 {
		t.Fatalf("章节数错误: 期望 70，实际 %d", len(chapters))
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

// —— 草榴社区：站点当前不可达，只做离线的规则语义校验 ——

func TestSourceT66yRulesOffline(t *testing.T) {
	src := loadSource(t, "t66y_book_source.json", "草榴社区-文学")

	if src.SearchUrl != "" {
		t.Errorf("该源只有发现，searchUrl 应为空: %q", src.SearchUrl)
	}
	// 列表页结构（按站点真实 DOM 的精简版）：#tbody tr.tr3 内是 td.tal > h3 > a
	const listHTML = `<html><body><table id="tbody">
	<tr class="tr3"><td class="tal"><h3><a id="t1234567" href="/read.php?tid=1234567">标题甲</a></h3></td>
	<td class="tal">[都市]</td><td><a class="bl">作者甲</a></td></tr>
	</table></body></html>`

	// 1. 列表规则命中 1 条
	ar := rule.New(src)
	ar.SetContent(listHTML, src.BookSourceUrl)
	els := ar.GetElements(src.GetExploreRule().BookList)
	if len(els) != 1 {
		t.Fatalf("列表规则未命中: %d", len(els))
	}

	// 2. 逐条按真实流程求值（每条规则都以列表元素为 content，result 也是该元素）
	item := rule.New(src)
	item.SetContent(els[0])
	if got := item.GetString("h3 a@text"); got != "标题甲" {
		t.Errorf("name 规则结果错误: %q", got)
	}
	if got := item.GetString("td a.bl@text"); got != "作者甲" {
		t.Errorf("author 规则结果错误: %q", got)
	}
	// `result.select('td.tal').text().match(/\[.*?\]/)` —— 验证 ElementWrap 的 select/text 可用
	if got := item.GetString(`@js:(result.select('td.tal').text().match(/\[.*?\]/)||[''])[0]`); got != "[都市]" {
		t.Errorf("kind JS 规则结果错误: %q", got)
	}
	// 详情地址由 JS 拼装，验证 ElementWrap#attr 与正则替换
	wantURL := "https://t66y.com/read.php?tid=1234567&fpage=0&toread=2"
	if got := item.GetString(`@js:'https://t66y.com/read.php?tid='+result.select('h3 a').attr('id').replace(/[^0-9]/g,'')+'&fpage=0&toread=2'`); got != wantURL {
		t.Errorf("bookUrl JS 规则结果错误: %q", got)
	}

	// 3. 目录规则：单章，标题固定
	ar.SetContent(listHTML, src.BookSourceUrl)
	if els := ar.GetElements(src.GetTocRule().ChapterList); len(els) != 1 {
		t.Errorf("chapterList JS 规则应返回 1 个元素，实际 %d", len(els))
	}
	if got := ar.GetString(src.GetTocRule().ChapterName); got != "正文" {
		t.Errorf("chapterName JS 规则结果错误: %q", got)
	}

	// 4. 正文规则：div.tpc_content@textNodes
	const contentHTML = `<html><body><div class="tpc_content">第一段<br>第二段</div></body></html>`
	cr := rule.New(src)
	cr.SetContent(contentHTML, src.BookSourceUrl)
	list := cr.GetStringList(src.GetContentRule().Content)
	if len(list) != 1 || !strings.Contains(list[0], "第一段") || !strings.Contains(list[0], "第二段") {
		t.Errorf("正文规则结果错误: %#v", list)
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
