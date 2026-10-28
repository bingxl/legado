package webbook_test

// 调试打点的回归测试：用录制快照把 搜索 → 详情 → 目录 → 正文 跑一遍，
// 断言每一步都留下了与客户端一致的阶段标记。打点被删或 state 用错时这里会失败。

import (
	"slices"
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/debug"
	"github.com/legado/legado-go/pkg/webbook"
)

// debugRecorder 收集全部调试记录。debug 包内部已串行化 Emit，这里不必加锁。
type debugRecorder struct{ entries []debug.Entry }

func (r *debugRecorder) Emit(e debug.Entry) { r.entries = append(r.entries, e) }

func (r *debugRecorder) states() []int {
	seen := map[int]bool{}
	var out []int
	for _, e := range r.entries {
		if !seen[e.State] {
			seen[e.State] = true
			out = append(out, e.State)
		}
	}
	slices.Sort(out)
	return out
}

func (r *debugRecorder) messages() string {
	var sb strings.Builder
	for _, e := range r.entries {
		sb.WriteString(e.Msg)
		sb.WriteByte('\n')
	}
	return sb.String()
}

func TestDebugTraceManhua(t *testing.T) {
	useVCR(t, "manhua")
	src := loadSource(t, "yumanhua_comic_source.json", "漫画客")

	rec := &debugRecorder{}
	debug.SetSink(rec)
	defer debug.SetSink(nil)

	// 1. 搜索
	list, err := webbook.SearchBook(src, "海贼", 1)
	if err != nil {
		t.Fatalf("搜索失败: %v", err)
	}
	if len(list) == 0 {
		t.Fatal("搜索无结果")
	}

	// 2. 详情
	book := list[0].ToBook()
	if err := webbook.GetBookInfo(src, book); err != nil {
		t.Fatalf("详情失败: %v", err)
	}

	// 3. 目录
	chapters, err := webbook.GetChapterList(src, book, false)
	if err != nil {
		t.Fatalf("目录失败: %v", err)
	}
	if len(chapters) == 0 {
		t.Fatal("目录为空")
	}

	// 4. 正文（与 testdata_source_test.go 用同一章，快照里录的就是它）
	if _, err := webbook.GetContent(src, book, chapters[1], ""); err != nil {
		t.Fatalf("正文失败: %v", err)
	}

	got := rec.messages()
	wants := []string{
		"≡获取成功:",  // 每次请求成功都要有
		"┌获取书籍列表", // 列表规则组
		"└列表大小:9", // 搜索结果数
		"┌获取书名",   // 首条字段日志
		"└海贼王",
		"◇书籍总数:9",
		"┌获取目录链接",
		"┌获取目录列表",
		"└目录列表解析完成",
		"◇目录总数:1201",
		"≡首章信息",
		"◇章节名称:",
		"┌获取章节名称",
		"┌获取正文内容",
	}
	// 该源配了 ruleBookInfo.init 时才应出现这条提示
	if src.GetBookInfoRule().Init != "" {
		wants = append(wants, "≡执行详情页初始化规则")
	}
	for _, want := range wants {
		if !strings.Contains(got, want) {
			t.Errorf("调试日志缺少 %q\n实际日志（前 2000 字）:\n%s", want, truncate(got, 2000))
		}
	}

	// 四个阶段的响应体都要落到对应 state，客户端靠它区分"查看源码"的归属
	states := rec.states()
	for _, want := range []int{debug.StateSearchBody, debug.StateInfoBody, debug.StateTocBody, debug.StateContentBody} {
		if !slices.Contains(states, want) {
			t.Errorf("缺少 state=%d 的响应体记录；实际 state 集合 %v", want, states)
		}
	}
	// webbook 层只打普通日志与响应体；"解析完成"由 CLI 编排层负责
	if !slices.Contains(states, debug.StateLog) {
		t.Errorf("普通日志缺失；实际 state 集合 %v", states)
	}
}

// TestDebugTraceOnlyFirstItemLogged 列表有 9 条，字段级日志只应对首条输出一次，
// 否则真实书源（几十条）会把调试流刷爆。
func TestDebugTraceOnlyFirstItemLogged(t *testing.T) {
	useVCR(t, "manhua")
	src := loadSource(t, "yumanhua_comic_source.json", "漫画客")

	rec := &debugRecorder{}
	debug.SetSink(rec)
	defer debug.SetSink(nil)

	if _, err := webbook.SearchBook(src, "海贼", 1); err != nil {
		t.Fatalf("搜索失败: %v", err)
	}

	if n := strings.Count(rec.messages(), "┌获取书名"); n != 1 {
		t.Errorf("┌获取书名 出现 %d 次，应只对首条打一次", n)
	}
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
