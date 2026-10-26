package source

import (
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/model"
)

func testSources() []*model.BookSource {
	return []*model.BookSource{
		{
			BookSourceName:  "VISTA看天下(纯发现源)",
			BookSourceUrl:   "https://open3.vistastory.com",
			BookSourceGroup: "kantianxia",
			FileName:        "kantianxia.json",
		},
		{
			BookSourceName:  "神奇漫画",
			BookSourceUrl:   "https://shenqimanhua.net",
			BookSourceGroup: "kantianxia",
			BookUrlPattern:  `https?://shenqimanhua\.net/comic/\w+`,
			FileName:        "kantianxia.json",
		},
		{
			BookSourceName:  "漫画客",
			BookSourceUrl:   "http://yumanhua.com",
			BookSourceGroup: "自用",
			FileName:        "yumanhua.json",
		},
	}
}

func TestFindByKeys(t *testing.T) {
	list := testSources()
	cases := []struct {
		key  string
		want string // 期望 bookSourceName；空串表示应找不到
	}{
		// 1. 序号
		{"1", "VISTA看天下(纯发现源)"},
		{"#2", "神奇漫画"},
		{"3", "漫画客"},
		{"4", ""},

		// 2. bookSourceUrl 全等（忽略大小写与末尾斜杠）
		{"https://shenqimanhua.net", "神奇漫画"},
		{"HTTPS://ShenqiManhua.net/", "神奇漫画"},

		// 3. 名称全等（忽略大小写不适用中文，但空格要容错）
		{"神奇漫画", "神奇漫画"},
		{"  漫画客  ", "漫画客"},

		// 4. 文件名（带/不带扩展名）
		{"yumanhua.json", "漫画客"},
		{"yumanhua", "漫画客"},
		{"kantianxia.json", "VISTA看天下(纯发现源)"}, // 同文件多源 → 取第一个
		{"/abs/path/to/yumanhua.json", "漫画客"},

		// 5. 详情页 URL 命中 bookUrlPattern
		{"https://shenqimanhua.net/comic/cmth4n6822q6hj8kwgfxp656u", "神奇漫画"},

		// 6. 域名（含 www. 与端口容错）
		{"shenqimanhua.net", "神奇漫画"},
		{"www.shenqimanhua.net", "神奇漫画"},
		{"https://shenqimanhua.net:8443/comics?page=2", "神奇漫画"},

		// 7. URL 子串
		{"vistastory", "VISTA看天下(纯发现源)"},

		// 8. 名称子串
		{"漫画", "神奇漫画"},

		// 9. 分组子串
		{"自用", "漫画客"},

		// 找不到
		{"不存在的源", ""},
		{"book.json", ""},
	}
	for _, c := range cases {
		got := Find(list, c.key)
		if c.want == "" {
			if got != nil {
				t.Errorf("Find(%q) 期望找不到，实际 %q", c.key, got.BookSourceName)
			}
			continue
		}
		if got == nil {
			t.Errorf("Find(%q) 期望 %q，实际 nil", c.key, c.want)
			continue
		}
		if got.BookSourceName != c.want {
			t.Errorf("Find(%q) 期望 %q，实际 %q", c.key, c.want, got.BookSourceName)
		}
	}
}

func TestFindEmptyKeyUsesFirst(t *testing.T) {
	list := testSources()
	if got := Find(list, ""); got == nil || got.BookSourceName != "VISTA看天下(纯发现源)" {
		t.Fatalf("空 key 应返回第一个书源，实际 %v", got)
	}
	if got := Find(nil, ""); got != nil {
		t.Fatalf("空列表应返回 nil，实际 %v", got.BookSourceName)
	}
}

// 文件名命中同一文件里的多个书源时，MatchAll 应全部返回，供 CLI 提示歧义
func TestMatchAllAmbiguous(t *testing.T) {
	list := testSources()
	m := MatchAll(list, "kantianxia.json")
	if len(m) != 2 {
		t.Fatalf("期望匹配 2 个，实际 %d", len(m))
	}
	// 名称精确匹配不应有歧义
	if m := MatchAll(list, "神奇漫画"); len(m) != 1 {
		t.Fatalf("精确名称应只匹配 1 个，实际 %d", len(m))
	}
}

func TestHintNotFound(t *testing.T) {
	h := HintNotFound(testSources())
	for _, want := range []string{"共 3 个", "神奇漫画", "kantianxia.json", "-source"} {
		if !strings.Contains(h, want) {
			t.Fatalf("提示缺少 %q:\n%s", want, h)
		}
	}
}
