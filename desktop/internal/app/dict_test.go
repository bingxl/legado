package app

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/legado/desktop/internal/app/dictdata"
	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// fakeDict 是内存版词库，用来验证回退链而不用真造 2 MB 的词库文件。
type fakeDict struct {
	words     map[string]domain.DictEntry
	forms     map[string]string
	formTypes map[string]string
	zh        map[string][]domain.DictEntry
	prefix    []string
}

func (f *fakeDict) LookupWord(_ context.Context, w string) (*domain.DictEntry, error) {
	if e, ok := f.words[w]; ok {
		return &e, nil
	}
	return nil, domain.ErrNotFound
}

func (f *fakeDict) LookupForm(_ context.Context, v string) (string, string, bool, error) {
	l, ok := f.forms[v]
	return l, f.formTypes[v], ok, nil
}

func (f *fakeDict) LookupZh(_ context.Context, w string) ([]domain.DictEntry, error) {
	return f.zh[w], nil
}

func (f *fakeDict) PrefixWords(_ context.Context, _ string, _ int) ([]string, error) {
	return f.prefix, nil
}

func (f *fakeDict) Close() error { return nil }

// newTestDict 构造一个使用内存词库的 DictService。
//
// 预置核心库文件是为了跳过内嵌解压：单测不该依赖构建产物，
// 也不该在临时目录里拷 2 MB。
func newTestDict(t *testing.T, repo *fakeDict, withZh bool) *DictService {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "dict")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	core := filepath.Join(dir, "en-zh.core."+dictdata.CoreVersion+".db")
	if err := os.WriteFile(core, []byte("fake"), 0o644); err != nil {
		t.Fatal(err)
	}
	if withZh {
		if err := os.WriteFile(filepath.Join(dir, "zh-en.db"), []byte("fake"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	svc := NewDictService(DictDeps{
		Root: root,
		OpenRepo: func(string) (port.DictionaryRepository, error) {
			return repo, nil
		},
	})
	t.Cleanup(func() { svc.Close() }) //nolint:errcheck
	return svc
}

func ctxOf() context.Context { return context.Background() }

func TestLookupExact(t *testing.T) {
	svc := newTestDict(t, &fakeDict{
		words: map[string]domain.DictEntry{
			"perceive": {Word: "perceive", Phonetic: "/pəˈsiːv/", Translation: "察觉，感知"},
		},
	}, false)

	got, err := svc.Lookup(ctxOf(), "Perceive", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.MatchedBy != dto.DictMatchExact {
		t.Fatalf("应精确命中，实际 %q", got.MatchedBy)
	}
	if got.Source != dto.DictSourceCore {
		t.Fatalf("应标注核心词库来源，实际 %q", got.Source)
	}
	if len(got.Entries) != 1 || got.Entries[0].Translation != "察觉，感知" {
		t.Fatalf("释义不对: %+v", got.Entries)
	}
	if got.Query != "perceive" {
		t.Fatalf("Query 应为归一化后的小写词，实际 %q", got.Query)
	}
}

func TestLookupFormFallback(t *testing.T) {
	svc := newTestDict(t, &fakeDict{
		words: map[string]domain.DictEntry{
			"perceive": {Word: "perceive", Translation: "察觉"},
		},
		// perceived 不在主表，只能靠词形表还原
		forms: map[string]string{"perceived": "perceive"},
	}, false)

	got, err := svc.Lookup(ctxOf(), "perceived", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.MatchedBy != dto.DictMatchForm {
		t.Fatalf("应走词形表，实际 %q", got.MatchedBy)
	}
	if got.Lemma != "perceive" {
		t.Fatalf("Lemma 应为原型，实际 %q", got.Lemma)
	}
	if !strings.Contains(got.FormLabel, "过去式") {
		t.Fatalf("必须说明这是过去式，否则用户以为查错词了，实际 %q", got.FormLabel)
	}
	if got.RuleGuess {
		t.Fatal("词形表命中的可信度高于规则还原，不应标 RuleGuess")
	}
}

func TestLookupRuleFallback(t *testing.T) {
	svc := newTestDict(t, &fakeDict{
		words: map[string]domain.DictEntry{
			"stop": {Word: "stop", Translation: "停止"},
		},
		// 故意不给词形表：逼它走规则还原（stopp → stop）
		forms: map[string]string{},
	}, false)

	got, err := svc.Lookup(ctxOf(), "stopped", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.MatchedBy != dto.DictMatchRule {
		t.Fatalf("应走规则还原，实际 %q", got.MatchedBy)
	}
	if !got.RuleGuess {
		t.Fatal("规则还原必须标 RuleGuess，供前端弱化可信度")
	}
	if got.Lemma != "stop" {
		t.Fatalf("规则还原结果应为 stop，实际 %q", got.Lemma)
	}
}

func TestLookupDehyphenate(t *testing.T) {
	svc := newTestDict(t, &fakeDict{
		words: map[string]domain.DictEntry{
			"long time": {Word: "long time", Translation: "长时间"},
		},
	}, false)

	got, err := svc.Lookup(ctxOf(), "long-time", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Entries) == 0 {
		t.Fatalf("应通过去连字符命中，实际 Hint=%q", got.Hint)
	}
}

func TestLookupSuggestsOnMiss(t *testing.T) {
	svc := newTestDict(t, &fakeDict{
		words:  map[string]domain.DictEntry{},
		prefix: []string{"perceive", "perceived", "percentage"},
	}, false)

	got, err := svc.Lookup(ctxOf(), "perceivd", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.MatchedBy != dto.DictMatchPrefix {
		t.Fatalf("未收录时应给前缀候选，实际 %q", got.MatchedBy)
	}
	if len(got.Suggestions) != 3 {
		t.Fatalf("候选数不对: %v", got.Suggestions)
	}
	if !strings.Contains(got.Hint, "未收录") {
		t.Fatalf("Hint 应说明未收录，实际 %q", got.Hint)
	}
}

func TestLookupSentenceHint(t *testing.T) {
	svc := newTestDict(t, &fakeDict{words: map[string]domain.DictEntry{}}, false)

	got, err := svc.Lookup(ctxOf(), "he walked into the room", "")
	if err != nil {
		t.Fatal(err)
	}
	if !got.Sentence {
		t.Fatal("超过 3 个英文词且未命中时，应标记为疑似整句")
	}
	if !strings.Contains(got.Hint, "整句翻译") {
		t.Fatalf("Hint 应引导去整句翻译，实际 %q", got.Hint)
	}
}

func TestLookupZhNotInstalled(t *testing.T) {
	svc := newTestDict(t, &fakeDict{}, false) // 没有 zh-en.db

	got, err := svc.Lookup(ctxOf(), "苹果", "")
	if err != nil {
		// 未安装是用户可修复的状态，不该当成系统故障
		t.Fatalf("未安装汉英词典不应返回错误: %v", err)
	}
	if got.Source != dto.DictSourceNone {
		t.Fatalf("来源应标为 none，实际 %q", got.Source)
	}
	if !strings.Contains(got.Hint, "未安装") {
		t.Fatalf("必须明确提示未安装，不能静默降级，实际 %q", got.Hint)
	}
}

func TestLookupZhLongestMatch(t *testing.T) {
	svc := newTestDict(t, &fakeDict{
		zh: map[string][]domain.DictEntry{
			"东西": {{Word: "东西", Pinyin: "dong xi", Translation: "thing; stuff"}},
		},
	}, true)

	got, err := svc.Lookup(ctxOf(), "他的东西", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Entries) != 1 || got.Entries[0].Word != "东西" {
		t.Fatalf("应最长匹配到「东西」，实际 %+v", got.Entries)
	}
	if !strings.Contains(got.Hint, "东西") {
		t.Fatalf("Hint 应说明按哪个子串给出的，实际 %q", got.Hint)
	}
}

func TestLookupZhSingleFallback(t *testing.T) {
	svc := newTestDict(t, &fakeDict{
		zh: map[string][]domain.DictEntry{
			"他": {{Word: "他", Pinyin: "ta", Translation: "he; him"}},
			"的": {{Word: "的", Pinyin: "de", Translation: "of; possessive particle"}},
		},
	}, true)

	got, err := svc.Lookup(ctxOf(), "他的", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.MatchedBy != dto.DictMatchSingle {
		t.Fatalf("应走单字兜底，实际 %q", got.MatchedBy)
	}
	if len(got.Entries) != 2 {
		t.Fatalf("应返回两个字各一条，实际 %d", len(got.Entries))
	}
	for _, e := range got.Entries {
		if e.Note != "按单字给出" {
			t.Fatalf("单字结果必须标注，实际 %q", e.Note)
		}
	}
}

func TestLookupZhDedup(t *testing.T) {
	svc := newTestDict(t, &fakeDict{
		zh: map[string][]domain.DictEntry{
			"苹果": {
				{Word: "苹果", Pinyin: "ping guo", Translation: "apple"},
				// CC-CEDICT 里同一词条常有多条重复记录，原样返回会让浮层出现两行一样的内容
				{Word: "苹果", Pinyin: "ping guo", Translation: "apple"},
			},
		},
	}, true)

	got, err := svc.Lookup(ctxOf(), "苹果", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Entries) != 1 {
		t.Fatalf("同拼音同释义应去重，实际 %d 条", len(got.Entries))
	}
}

func TestLookupEmptySelection(t *testing.T) {
	svc := newTestDict(t, &fakeDict{}, false)

	got, err := svc.Lookup(ctxOf(), "  ", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.MatchedBy != dto.DictMatchNone {
		t.Fatalf("空选区应返回 none，实际 %q", got.MatchedBy)
	}
	if got.Hint == "" {
		t.Fatal("空选区要给提示语，不能静默返回空结果")
	}
}
