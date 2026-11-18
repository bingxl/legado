package domain

import (
	"reflect"
	"testing"
)

func TestNormalizeQuery(t *testing.T) {
	cases := []struct {
		name     string
		in       string
		wantWord string
		wantDir  Direction
	}{
		{"英文小写化", "Perceived", "perceived", DirectionEnZh},
		{"去首尾标点", "\"perceive,\"", "perceive", DirectionEnZh},
		{"弯引号还原后去边缘", "\u2019perceive\u2019", "perceive", DirectionEnZh},
		{"词内撇号保留", "reader's", "reader's", DirectionEnZh},
		{"词内连字符保留", "half-an-hour", "half-an-hour", DirectionEnZh},
		{"压缩内部空白", "New   York", "new york", DirectionEnZh},
		{"中文不改变大小写", "东西", "东西", DirectionZhEn},
		{"中文去句号", "东西。", "东西", DirectionZhEn},
		{"中英混排判为中文", "hello 世界", "hello 世界", DirectionZhEn},
		{"纯标点为空", "——", "", ""},
		{"纯空白为空", "   \n\t ", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			word, dir := NormalizeQuery(c.in)
			if word != c.wantWord || dir != c.wantDir {
				t.Fatalf("NormalizeQuery(%q) = (%q, %q)，期望 (%q, %q)",
					c.in, word, dir, c.wantWord, c.wantDir)
			}
		})
	}
}

func TestNormalizeQueryTruncates(t *testing.T) {
	long := ""
	for i := 0; i < MaxQueryRune+50; i++ {
		long += "a"
	}
	word, _ := NormalizeQuery(long)
	if n := len([]rune(word)); n != MaxQueryRune {
		t.Fatalf("超长选区应截断到 %d 个字符，实际 %d", MaxQueryRune, n)
	}
}

func TestHasCJK(t *testing.T) {
	if !HasCJK("东西") {
		t.Fatal("「东西」应判为含汉字")
	}
	if HasCJK("hello — world") {
		t.Fatal("纯英文与破折号不应判为含汉字")
	}
}

func TestEnglishCandidates(t *testing.T) {
	cases := []struct {
		word string
		want string
	}{
		{"perceived", "perceive"}, // -ed 去 e
		{"running", "run"},        // -ing 去重复辅音
		{"studies", "study"},      // -ies → y
		{"boxes", "box"},          // -es → ∅
		{"reader's", "reader"},    // 所有格
		{"happier", "happy"},      // -ier → y
		{"quickly", "quick"},      // -ly
	}
	for _, c := range cases {
		got := EnglishCandidates(c.word)
		if !contains(got, c.want) {
			t.Fatalf("EnglishCandidates(%q)=%v，应包含 %q", c.word, got, c.want)
		}
	}
}

func TestEnglishCandidatesNoSelf(t *testing.T) {
	// 规则不能把原形自己当候选还给调用方，否则上层会做一次无意义的重复查询。
	for _, w := range []string{"during", "spring", "is"} {
		for _, c := range EnglishCandidates(w) {
			if c == w {
				t.Fatalf("EnglishCandidates(%q) 返回了自身", w)
			}
		}
	}
}

func TestChineseSegments(t *testing.T) {
	segs := ChineseSegments("他的东西")
	// 最长优先：第一个必须是原串
	if len(segs) == 0 || segs[0] != "他的东西" {
		t.Fatalf("最长匹配应从原串开始，实际 %v", segs)
	}
	if !contains(segs, "东西") {
		t.Fatalf("应包含子串「东西」，实际 %v", segs)
	}
	// 单字不在此函数内，由调用方兜底
	if contains(segs, "的") {
		t.Fatal("ChineseSegments 不应返回单字")
	}
}

func TestChineseSegmentsWindow(t *testing.T) {
	long := "一二三四五六七八九十"
	segs := ChineseSegments(long)
	if len(segs) == 0 {
		t.Fatal("长选区应仍产生候选")
	}
	maxLen := 0
	for _, s := range segs {
		if n := len([]rune(s)); n > maxLen {
			maxLen = n
		}
	}
	if maxLen != MaxChineseWordRune {
		t.Fatalf("搜索窗口应截到 %d 字，实际最长 %d", MaxChineseWordRune, maxLen)
	}
}

func TestChineseSingles(t *testing.T) {
	got := ChineseSingles("他的东西")
	want := []string{"他", "的", "东", "西"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ChineseSingles = %v，期望 %v", got, want)
	}
}

func contains(list []string, target string) bool {
	for _, s := range list {
		if s == target {
			return true
		}
	}
	return false
}
