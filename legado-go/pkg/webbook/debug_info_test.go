package webbook

// 详情页字段日志的语义回归：Kotlin 的 └ 打印的是「规则求值结果」，
// 不是合并进 book 之后的字段值。两者在"规则取空但保留旧值"时会分叉，
// 而这个分叉恰好是书源作者判断规则是否失效的关键信号，必须钉住。

import (
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/debug"
	"github.com/legado/legado-go/pkg/model"
)

type sinkRecorder struct{ entries []debug.Entry }

func (r *sinkRecorder) Emit(e debug.Entry) { r.entries = append(r.entries, e) }

func (r *sinkRecorder) all() string {
	var sb strings.Builder
	for _, e := range r.entries {
		sb.WriteString(e.Msg)
		sb.WriteByte('\n')
	}
	return sb.String()
}

func TestAnalyzeBookInfoLogsRuleResult(t *testing.T) {
	src := &model.BookSource{
		BookSourceUrl:  "debug-test",
		BookSourceName: "详情页日志测试",
		RuleBookInfo: &model.BookInfoRule{
			// 页面标题是 <h1>，这条规则命中不了，模拟站点改版后的失效规则
			Name: ".top h2@text",
			// 这条会命中 .fix 下的两个 <p>，Kotlin 用 "\n" 拼接
			Author: ".top .fix p@text",
		},
	}
	book := model.NewBook()
	book.BookUrl = "https://example.com/book/1"
	book.Name = "旧书名"
	book.Author = "旧作者"

	rec := &sinkRecorder{}
	debug.SetSink(rec)
	defer debug.SetSink(nil)

	// canReName=false 且字段已有值 → 规则结果不会写回 book，只会出现在日志里
	body := `<div class="top"><h1>监禁王</h1>
		<div class="fix"><p>作&nbsp;&nbsp;者：マサイ</p><p>状&nbsp;&nbsp;态：连载中</p></div></div>`
	if err := analyzeBookInfo(src, book, "https://example.com/book/1", "https://example.com/book/1", body); err != nil {
		t.Fatalf("详情页解析失败: %v", err)
	}

	got := rec.all()
	// 书名规则不命中 → 日志空；旧值保留在 book 上（Kotlin 同此行为）
	if block := logBlock(t, got, "获取书名", "获取作者"); block != "" {
		t.Errorf("书名日志应打印空的规则结果，实际 %q\n完整日志:\n%s", block, got)
	}
	if book.Name != "旧书名" {
		t.Errorf("旧书名应保留，实际 %q", book.Name)
	}
	// 作者规则命中 → 日志是规则结果（两个 <p> 用 \n 拼接），而不是 book 里的旧作者
	block := logBlock(t, got, "获取作者", "获取分类")
	if !strings.Contains(block, "マサイ") || !strings.Contains(block, "连载中") {
		t.Errorf("作者日志应是规则求值结果，实际 %q\n完整日志:\n%s", block, got)
	}
	if strings.Contains(block, "旧作者") {
		t.Errorf("作者日志不应打印合并后的字段值，实际 %q", block)
	}
	if book.Author != "旧作者" {
		t.Errorf("canReName=false 时不应改写作者，实际 %q", book.Author)
	}
}

// logBlock 取出 "┌label\n└value" 中的 value（到下一个 ┌ 之前）。
func logBlock(t *testing.T, log, label, next string) string {
	t.Helper()
	head := "┌" + label + "\n└"
	i := strings.Index(log, head)
	if i < 0 {
		t.Fatalf("日志缺少 %q\n完整日志:\n%s", head, log)
	}
	rest := log[i+len(head):]
	if j := strings.Index(rest, "┌"+next); j >= 0 {
		rest = rest[:j]
	}
	// all() 给每条记录补了换行，取值时去掉尾部空行
	return strings.TrimRight(rest, "\n")
}
