package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/legado/desktop/internal/adapter/dictsqlite"
	"github.com/legado/desktop/internal/app/dictdata"
	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/port"
)

// TestCorePackUsable 用**真实的**内嵌词库验证构建产物可用。
//
// 它守的是两件容易悄悄坏掉的事：
//  1. dictdata/en-zh.core.v1.db.gz 是不是真的被打进二进制了（空了、schema 变了）；
//  2. had / were / been 这类「自动生成的变化形式」是不是还在。
//
// 第 2 条是设计方案 §0 结论 1 记下的坑：按词频裁剪时如果不单独保留词形表，
// 这批最常用的词会整批消失，而这正是阅读场景最高频的词。
func TestCorePackUsable(t *testing.T) {
	root := t.TempDir()
	svc := NewDictService(DictDeps{
		Root: root,
		OpenRepo: func(path string) (port.DictionaryRepository, error) {
			return dictsqlite.OpenReadOnly(path)
		},
	})
	t.Cleanup(func() { svc.Close() }) //nolint:errcheck

	// 让解压真的发生一次
	if _, err := svc.ensureCore(); err != nil {
		t.Fatalf("解压内置词库失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "dict", "en-zh.core."+dictdata.CoreVersion+".db")); err != nil {
		t.Fatalf("词库未落盘: %v", err)
	}

	cases := []struct {
		query     string
		wantMatch string
		wantLemma string
		wantLabel string // 只对词形命中检查
	}{
		{"perceive", dto.DictMatchExact, "", ""},
		// perceived 在 ECDICT 里本身就是独立词条（有词频与考试标签），
		// 所以走精确命中而不是词形回退——这比预期更好。
		{"perceived", dto.DictMatchExact, "", ""},
		// 下面三个是 R5 那条坑的守卫：它们**只能**靠词形表查出来，
		// 词频裁剪时若把词形表一起裁掉，这三个词就全查不到了。
		{"had", dto.DictMatchForm, "have", "过去式/过去分词"},
		{"were", dto.DictMatchForm, "be", ""},
		{"been", dto.DictMatchForm, "be", ""},
		{"blorptastic", dto.DictMatchNone, "", ""}, // 确实不存在的词要如实说未收录
	}
	for _, c := range cases {
		got, err := svc.Lookup(ctxOf(), c.query, "")
		if err != nil {
			t.Fatalf("查 %q 失败: %v", c.query, err)
		}
		if got.MatchedBy != c.wantMatch {
			t.Errorf("查 %q 的命中方式 = %q，期望 %q（Hint=%q, 候选=%v）",
				c.query, got.MatchedBy, c.wantMatch, got.Hint, got.Suggestions)
			continue
		}
		if c.wantLemma != "" && got.Lemma != c.wantLemma {
			t.Errorf("查 %q 的 Lemma = %q，期望 %q", c.query, got.Lemma, c.wantLemma)
		}
		if c.wantLabel != "" && got.FormLabel != c.wantLabel {
			t.Errorf("查 %q 的 FormLabel = %q，期望 %q", c.query, got.FormLabel, c.wantLabel)
		}
		if c.wantMatch != dto.DictMatchNone && len(got.Entries) == 0 {
			t.Errorf("查 %q 命中却没有释义", c.query)
		}
		if c.wantMatch == dto.DictMatchNone && got.Hint == "" {
			t.Errorf("查 %q 未命中却没给提示", c.query)
		}
	}
}

// TestCorePackStatus 校验设置页读到的状态与产物事实一致。
func TestCorePackStatus(t *testing.T) {
	root := t.TempDir()
	svc := NewDictService(DictDeps{
		Root: root,
		OpenRepo: func(path string) (port.DictionaryRepository, error) {
			return dictsqlite.OpenReadOnly(path)
		},
	})
	t.Cleanup(func() { svc.Close() }) //nolint:errcheck

	st := svc.Status(ctxOf())
	if !st.Ready {
		t.Fatal("核心词库就绪后 Ready 应为真")
	}
	if len(st.Packages) == 0 {
		t.Fatal("应至少返回核心词库一项")
	}
	core := st.Packages[0]
	if !core.Builtin || !core.Installed {
		t.Fatalf("核心词库应标为内置且已安装: %+v", core)
	}
	if core.Entries <= 0 {
		t.Fatalf("词条数应大于 0，实际 %d", core.Entries)
	}
	// 汉字包没装时应如实反映，不能显示已安装
	for _, p := range st.Packages[1:] {
		if p.Installed {
			t.Fatalf("%s 未安装却被标为已安装", p.ID)
		}
	}
}

// TestCorePackExtractedOnce 验证重复调用不会重复解压、也不会留下多份旧库。
func TestCorePackExtractedOnce(t *testing.T) {
	root := t.TempDir()
	svc := NewDictService(DictDeps{
		Root: root,
		OpenRepo: func(path string) (port.DictionaryRepository, error) {
			return dictsqlite.OpenReadOnly(path)
		},
	})
	t.Cleanup(func() { svc.Close() }) //nolint:errcheck

	first, err := svc.ensureCore()
	if err != nil {
		t.Fatal(err)
	}
	second, err := svc.ensureCore()
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("第二次应复用已打开的连接，而不是重新解压打开")
	}

	matches, err := filepath.Glob(filepath.Join(root, "dict", "en-zh.core.*.db"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 1 {
		t.Fatalf("应只保留一份核心词库，实际 %v", matches)
	}
	if strings.HasSuffix(matches[0], ".tmp") {
		t.Fatalf("不应残留临时文件: %s", matches[0])
	}
}
