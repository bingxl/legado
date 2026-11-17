package source

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/model"
)

const testdataDir = "../../testdata/sources"

// TestLoadTestdataSources 校验 testdata 下的真实书源能被完整加载
func TestLoadTestdataSources(t *testing.T) {
	list, errs := LoadDir(testdataDir)
	if len(errs) > 0 {
		t.Fatalf("加载出错: %v", errs)
	}
	if len(list) != 4 {
		t.Fatalf("书源数量错误: 期望 4，实际 %d", len(list))
	}
	want := map[string]string{
		"t66y":  "t66y_book_source.json",
		"狼人小说":  "t66y_book_source.json",
		"漫画客":   "yumanhua_comic_source.json",
		"爱丽丝书屋": "alicesw_book_source.json",
	}
	got := map[string]string{}
	for _, s := range list {
		got[s.BookSourceName] = filepath.Base(s.FileName)
	}
	for name, file := range want {
		if got[name] != file {
			t.Errorf("书源 %q 来源文件错误: 期望 %q，实际 %q", name, file, got[name])
		}
	}

	// 单文件多源：t66y_book_source.json 里有两个源，按名字要能精确命中
	t66y, err := LoadFile(filepath.Join(testdataDir, "t66y_book_source.json"))
	if err != nil {
		t.Fatalf("加载 t66y_book_source.json 失败: %v", err)
	}
	if len(t66y) != 2 {
		t.Fatalf("t66y_book_source.json 源数量错误: %d", len(t66y))
	}
	if s := Find(t66y, "狼人小说"); s == nil || s.BookSourceName != "狼人小说" {
		t.Errorf("按名称查找失败: %+v", s)
	}
	if s := Find(t66y, "t66y_book_source.json"); s == nil {
		t.Errorf("按文件名查找失败（多源文件应命中首个）")
	}
}

// TestValidateTestdataSources 三个真实书源都必须通过语法校验
func TestValidateTestdataSources(t *testing.T) {
	list, errs := LoadDir(testdataDir)
	if len(errs) > 0 {
		t.Fatalf("加载出错: %v", errs)
	}
	for _, s := range list {
		r := Validate(s)
		if !r.OK() {
			for _, is := range r.Issues {
				if is.Level == LevelError {
					t.Errorf("[%s] %s: %s", s.BookSourceName, is.Field, is.Message)
				}
			}
			continue
		}
		t.Logf("[%s] 校验通过（%d 条提示）", s.BookSourceName, len(r.Issues))
	}
}

// TestSourceShapes 关键字段的结构断言，防止书源文件被误改
func TestSourceShapes(t *testing.T) {
	list, _ := LoadDir(testdataDir)
	byName := map[string]bool{}
	for _, s := range list {
		byName[s.BookSourceName] = true
		switch s.BookSourceName {
		case "漫画客":
			if s.BookSourceType != 2 {
				t.Errorf("漫画客类型应为 2（图片/漫画），实际 %d", s.BookSourceType)
			}
			kinds := model.ParseExploreKinds(s.ExploreUrl)
			if len(kinds) < 3 {
				t.Errorf("漫画客分类数量异常: %d", len(kinds))
			} else if kinds[0].Title != "冒险" || !strings.Contains(kinds[0].Url, "/data/sort") {
				t.Errorf("漫画客首个分类异常: %+v", kinds[0])
			}
			if !strings.Contains(s.SearchUrl, `"method":"POST"`) {
				t.Errorf("漫画客搜索应为 POST: %s", s.SearchUrl)
			}
			if s.GetTocRule().ChapterList == "" || !strings.HasPrefix(s.GetTocRule().ChapterList, "@js:") {
				t.Errorf("漫画客目录规则应为 JS: %.40q", s.GetTocRule().ChapterList)
			}
		case "狼人小说":
			if !strings.Contains(s.SearchUrl, "charset") || !strings.Contains(s.SearchUrl, "gbk") {
				t.Errorf("狼人小说搜索应声明 gbk: %s", s.SearchUrl)
			}
			kinds := model.ParseExploreKinds(s.ExploreUrl)
			if len(kinds) == 0 || !strings.Contains(kinds[0].Url, "{{page") {
				t.Errorf("狼人小说分类地址应含 {{page}}: %+v", kinds)
			}
			if got := s.GetTocRule().ChapterUrl; got != "href" {
				t.Errorf("狼人小说 chapterUrl 应为单段属性名 href，实际 %q", got)
			}
		case "爱丽丝书屋":
			if s.BookSourceType != 0 {
				t.Errorf("爱丽丝书屋类型应为 0（文本），实际 %d", s.BookSourceType)
			}
			if !strings.Contains(s.SearchUrl, "/search.html?q={{key}}") {
				t.Errorf("爱丽丝书屋搜索地址异常: %s", s.SearchUrl)
			}
			// ★ 回归：tocUrl 必须取详情页「查看所有章节」的链接。
			// 详情 ID 与章节页 ID 不同，用详情 URL 拼章节地址会 404（正文解析为空）。
			if tu := s.GetBookInfoRule().TocUrl; !strings.Contains(tu, "book_newchap") {
				t.Errorf("爱丽丝书屋 tocUrl 须取 book_newchap 内的链接: %q", tu)
			}
			if c := s.GetContentRule().Content; !strings.Contains(c, "read-content") {
				t.Errorf("爱丽丝书屋正文规则异常: %s", c)
			}
			kinds := model.ParseExploreKinds(s.ExploreUrl)
			if len(kinds) < 30 || kinds[0].Url != "/lists/71.html?page={{page}}" {
				t.Errorf("爱丽丝书屋发现分类异常: 共 %d 个，首个 %+v", len(kinds), kinds[0])
			}
		case "t66y":
			if s.SearchUrl != "" {
				t.Errorf("t66y 只有发现，searchUrl 应为空: %q", s.SearchUrl)
			}
			if s.GetTocRule().ChapterList == "" {
				t.Errorf("t66y 目录规则为空")
			}
			if !strings.Contains(s.GetContentRule().Content, "tpc_content") {
				t.Errorf("t66y 正文规则异常: %s", s.GetContentRule().Content)
			}
			// ★ 回归：bookUrl 的 ## 替换必须吃掉整条 /htm_data/... 路径。
			// 只替换文件名会产出 /htm_data/2611/20//read.php?tid=x，站点回 404，
			// 表现为「正文解析结果为空」。
			if br := s.GetExploreRule().BookUrl; !strings.Contains(br, "^.*/") {
				t.Errorf("t66y bookUrl 替换正则须从行首吃掉路径: %q", br)
			}
			kinds := model.ParseExploreKinds(s.ExploreUrl)
			if len(kinds) < 2 || !strings.Contains(kinds[0].Url, "fid=20") {
				t.Errorf("t66y 发现分类异常: %+v", kinds)
			}
		default:
			t.Errorf("未预期的书源: %s", s.BookSourceName)
		}
	}
	for _, n := range []string{"漫画客", "狼人小说", "t66y", "爱丽丝书屋"} {
		if !byName[n] {
			t.Errorf("缺少书源: %s", n)
		}
	}
}
