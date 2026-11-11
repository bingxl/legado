package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/legado/desktop/internal/app/dictdata"
	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

const (
	// dictSuggestLimit 是「你是不是要找…」的候选上限。
	//
	// 超过 5 条用户就不会看了，反而挤占浮层空间。
	dictSuggestLimit = 5
	// dictSentenceWords 英文超过这么多词就判定为句子。
	dictSentenceWords = 3
	// dictSentenceHanzi 中文达到这么多汉字就判定为句子。
	dictSentenceHanzi = 10
)

// DictDeps 聚合词典服务的依赖。
type DictDeps struct {
	// Root 是应用数据目录，词库落在 <Root>/dict/ 下。
	Root string
	// Settings 用于记录已解压的核心词库版本与下载源配置。
	Settings port.SettingsStore
	// Events 用于推送扩展包安装进度（M4 使用）。
	Events port.EventBus
	// OpenRepo 由 bootstrap 注入，通常是 dictsqlite.OpenReadOnly。
	//
	// 之所以用函数注入而不直接 import 适配器：internal/app 依赖 port 与 domain，
	// 不依赖任何具体实现（见 ARCHITECTURE.md 的分层约定）。注入之后
	// 单测可以塞一个内存实现。
	OpenRepo func(path string) (port.DictionaryRepository, error)
	// Build 把上游源文件转换成本地词库，同样由 bootstrap 注入。
	//
	// 与 OpenRepo 同理：转换器在 internal/adapter/dictbuild，app 层不认识它。
	// 签名里的 progress 回调用来推进度事件，done/total 是字节数。
	Build func(ctx context.Context, kind, srcPath, outPath, tier string, progress func(done, total int64)) (int, error)
}

// DictService 提供阅读器取词能力。
//
// 设计要点：
//  1. 词库是**只读产物**，与 legado.db 完全独立：不进迁移、不参与事务，
//     坏了删掉重装即可，不牵连阅读数据；
//  2. 核心词库随二进制内嵌，首次查词时解压一次，此后永不联网；
//  3. 查不到时**不返回错误**，而是返回带 Hint 的结果——「未收录」是正常状态，
//     不是系统故障，前端要能区分这两者。
type DictService struct {
	root     string
	settings port.SettingsStore
	events   port.EventBus
	openRepo func(path string) (port.DictionaryRepository, error)
	build    func(ctx context.Context, kind, srcPath, outPath, tier string, progress func(done, total int64)) (int, error)

	mu     sync.Mutex
	opened map[string]port.DictionaryRepository

	// jobs 是正在进行的安装任务，按包 ID 互斥（见 dict_install.go）。
	jobsMu sync.Mutex
	jobs   map[string]*dictJob
	// seq 是进度事件的单调序号，前端据此丢弃迟到事件。
	seq atomic.Int64
}

// NewDictService 创建词典服务。词库在首次查词时才解压与打开。
func NewDictService(deps DictDeps) *DictService {
	return &DictService{
		root:     deps.Root,
		settings: deps.Settings,
		events:   deps.Events,
		openRepo: deps.OpenRepo,
		build:    deps.Build,
		opened:   make(map[string]port.DictionaryRepository, 3),
		jobs:     make(map[string]*dictJob, 2),
	}
}

// Close 释放已打开的词库连接。
func (s *DictService) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var firstErr error
	for name, repo := range s.opened {
		if err := repo.Close(); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("关闭词库 %s: %w", name, err)
		}
		delete(s.opened, name)
	}
	return firstErr
}

// Lookup 查词。hint 为 en / zh 时强制方向，其余情况按内容自动判定。
func (s *DictService) Lookup(ctx context.Context, text, hint string) (dto.DictResultView, error) {
	word, direction := domain.NormalizeQuery(text)
	if word == "" {
		return dto.DictResultView{
			MatchedBy: dto.DictMatchNone,
			Hint:      "选区里没有可查的文字",
		}, nil
	}
	switch hint {
	case "en", string(domain.DirectionEnZh):
		direction = domain.DirectionEnZh
	case "zh", string(domain.DirectionZhEn):
		direction = domain.DirectionZhEn
	}
	if direction == domain.DirectionZhEn {
		return s.lookupZh(ctx, word)
	}
	return s.lookupEn(ctx, word)
}

// lookupEn 实现英 → 中的五级回退（设计方案 §6.2）。
//
// 回退链的存在理由只有一条：实测「只做精确匹配」在 top30k 档只有 91.99% 词次覆盖，
// 加上词形表能到 98.74%。不做回退，用户查 was / had / went 全是「未收录」——
// 而这是阅读场景最常见的三个词。
func (s *DictService) lookupEn(ctx context.Context, word string) (dto.DictResultView, error) {
	view := dto.DictResultView{
		Query:     word,
		Direction: string(domain.DirectionEnZh),
		Source:    dto.DictSourceCore,
		MatchedBy: dto.DictMatchNone,
	}
	sentence := domain.QueryWords(word) > dictSentenceWords

	repo, source, err := s.englishRepo()
	if err != nil {
		// 核心词库不可用属于系统故障（磁盘满、内置数据损坏），必须把错误抛上去，
		// 与「未收录」严格区分。
		return view, err
	}
	view.Source = source

	// ① 主表精确
	if e, err := repo.LookupWord(ctx, word); err == nil {
		view.MatchedBy = dto.DictMatchExact
		view.Entries = oneEntry(*e)
		return view, nil
	} else if !errors.Is(err, domain.ErrNotFound) {
		return view, err
	}

	// ② 词形表还原（56409 条，覆盖规则的绝大多数场景）
	if lemma, types, ok, err := repo.LookupForm(ctx, word); err != nil {
		return view, err
	} else if ok {
		if e, err := repo.LookupWord(ctx, lemma); err == nil {
			return variantView(view, word, lemma, types, dto.DictMatchForm, false, *e), nil
		}
	}

	// ③ 规则还原：词形表漏收的变形（没有关系类型，说明只能靠后缀猜）
	for _, cand := range domain.EnglishCandidates(word) {
		e, err := repo.LookupWord(ctx, cand)
		if err == nil {
			return variantView(view, word, cand, "", dto.DictMatchRule, true, *e), nil
		}
		if !errors.Is(err, domain.ErrNotFound) {
			return view, err
		}
	}

	// ④ 连字符/空格归一：long-time ↔ longtime、ice-cream ↔ ice cream
	if alt := dehyphenate(word); alt != "" && alt != word {
		if e, err := repo.LookupWord(ctx, alt); err == nil {
			view.MatchedBy = dto.DictMatchExact
			view.Entries = oneEntry(*e)
			view.Hint = "按去掉连字符的写法给出「" + alt + "」"
			return view, nil
		}
	}

	// ⑤ 前缀猜测
	sugg, err := repo.PrefixWords(ctx, prefixOf(word), dictSuggestLimit)
	if err != nil {
		return view, err
	}
	if len(sugg) > 0 {
		view.MatchedBy = dto.DictMatchPrefix
		view.Suggestions = sugg
	}
	view.Hint = "词库未收录「" + word + "」"
	if sentence {
		view.Sentence = true
		if len(sugg) > 0 {
			view.Hint = "这看起来是一整句，建议用整句翻译（也可以先看相近词）"
		} else {
			view.Hint = "这看起来是一整句，建议用整句翻译"
		}
	}
	return view, nil
}

// lookupZh 实现中 → 英的最长匹配（设计方案 §6.3）。
func (s *DictService) lookupZh(ctx context.Context, word string) (dto.DictResultView, error) {
	view := dto.DictResultView{
		Query:     word,
		Direction: string(domain.DirectionZhEn),
		Source:    dto.DictSourceCedict,
		MatchedBy: dto.DictMatchNone,
	}
	repo, err := s.zhRepo()
	if err != nil {
		// 「没装汉英包」是用户可自行修复的状态，给提示而不是报错。
		view.Source = dto.DictSourceNone
		view.Hint = "尚未安装汉英词典，可在设置里下载（约 14 MB）"
		return view, nil
	}

	// ① 精确
	if entries, err := s.lookupZhEntries(ctx, repo, word); err != nil {
		return view, err
	} else if len(entries) > 0 {
		view.MatchedBy = dto.DictMatchExact
		view.Entries = entries
		return view, nil
	}

	// ② 最长匹配：从长到短切子串，取第一个命中的
	for _, seg := range domain.ChineseSegments(word) {
		entries, err := s.lookupZhEntries(ctx, repo, seg)
		if err != nil {
			return view, err
		}
		if len(entries) > 0 {
			view.MatchedBy = dto.DictMatchExact
			view.Entries = entries
			view.Hint = "按最长匹配给出「" + seg + "」"
			return view, nil
		}
	}

	// ③ 单字兜底
	var singles []dto.DictEntryView
	for _, ch := range domain.ChineseSingles(word) {
		entries, err := s.lookupZhEntries(ctx, repo, ch)
		if err != nil {
			return view, err
		}
		for _, e := range entries {
			e.Note = "按单字给出"
			singles = append(singles, e)
		}
	}
	if len(singles) > 0 {
		view.MatchedBy = dto.DictMatchSingle
		view.Entries = singles
		view.Hint = "未收录「" + word + "」，按单字给出"
		return view, nil
	}

	if domain.CountCJK(word) >= dictSentenceHanzi {
		view.Sentence = true
		view.Hint = "这看起来是一整句，建议用整句翻译"
	} else {
		view.Hint = "汉英词典未收录「" + word + "」"
	}
	return view, nil
}

// Status 返回词库包状态，供设置页展示。
//
// 扩展包按**内嵌清单**枚举，而不是按目录里有什么文件枚举：
// 清单才是「这个版本的应用认识哪些包」的权威，扫目录会把用户
// 手工扔进去的无关 .db 也列出来。
func (s *DictService) Status(ctx context.Context) dto.DictStatusView {
	var out dto.DictStatusView
	dir := filepath.Join(s.root, "dict")

	if _, err := s.ensureCore(); err == nil {
		out.Ready = true
	}
	out.Packages = append(out.Packages, dto.DictPackageView{
		ID:          "en-zh-core",
		Name:        "内置核心词库",
		Size:        s.fileSize(filepath.Join(dir, "en-zh.core."+dictdata.CoreVersion+".db")),
		Entries:     dictdata.CoreEntries,
		Version:     dictdata.CoreVersion,
		BuiltAt:     dictdata.CoreBuiltAt,
		Builtin:     true,
		Installed:   out.Ready,
		SourceLabel: "ECDICT 常用 3.8 万词条（MIT 许可），随应用分发",
	})

	packs, err := dictdata.ExtPacks()
	if err != nil {
		// 清单损坏不该让整张卡片消失：核心库那段仍然有用。
		return out
	}
	for _, p := range packs {
		path := filepath.Join(dir, p.FileName)
		out.Packages = append(out.Packages, dto.DictPackageView{
			ID:            p.ID,
			Name:          p.Name,
			Size:          s.fileSize(path),
			Entries:       p.Entries,
			Version:       p.Tier,
			BuiltAt:       p.BuiltAt,
			Installed:     fileExists(path),
			DownloadBytes: p.DownloadBytes,
			SourceLabel:   p.SourceLabel,
			Removable:     true,
		})
	}
	return out
}

// ── 词库打开与解压 ──────────────────────────────────────────────

// englishRepo 返回可用的英文词库，优先用扩展包。
//
// 全量包存在时直接用它：两者的 schema 完全一致，只是词条数不同，
// 上层不需要知道当前用的是哪一档。
func (s *DictService) englishRepo() (port.DictionaryRepository, string, error) {
	for _, name := range []string{"en-zh.full.db", "en-zh.standard.db"} {
		if repo, ok := s.tryOpenPackage(name); ok {
			return repo, dto.DictSourceFull, nil
		}
	}
	repo, err := s.ensureCore()
	if err != nil {
		return nil, dto.DictSourceNone, err
	}
	return repo, dto.DictSourceCore, nil
}

// zhRepo 返回汉英词库；未安装时返回 domain.ErrNotConfigured。
func (s *DictService) zhRepo() (port.DictionaryRepository, error) {
	if repo, ok := s.tryOpenPackage("zh-en.db"); ok {
		return repo, nil
	}
	return nil, domain.ErrNotConfigured
}

// tryOpenPackage 在扩展包文件存在时打开它，并按文件名缓存连接。
func (s *DictService) tryOpenPackage(name string) (port.DictionaryRepository, bool) {
	path := filepath.Join(s.root, "dict", name)
	if !fileExists(path) {
		return nil, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if repo, ok := s.opened[name]; ok {
		return repo, true
	}
	repo, err := s.openRepo(path)
	if err != nil {
		// 扩展包损坏时不让它拖垮整个查词：返回 false 让调用方回退到核心库。
		return nil, false
	}
	s.opened[name] = repo
	return repo, true
}

// ensureCore 解压并打开内置核心词库。
//
// 只在首次查词时执行（解压约 10 ms 量级）。失败不缓存错误：
// 磁盘临时满过之后又恢复的场景，缓存错误会让整个会话都用不了词典。
func (s *DictService) ensureCore() (port.DictionaryRepository, error) {
	dir := filepath.Join(s.root, "dict")
	target := filepath.Join(dir, "en-zh.core."+dictdata.CoreVersion+".db")

	s.mu.Lock()
	if repo, ok := s.opened[target]; ok {
		s.mu.Unlock()
		return repo, nil
	}
	s.mu.Unlock()

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("创建词典目录 %q 失败: %w", dir, err)
	}
	if !fileExists(target) {
		if err := dictdata.ExtractCore(target); err != nil {
			return nil, err
		}
		// 解压成功后清掉旧版本，避免 <data>/dict 无限膨胀。
		cleanOldCore(dir, filepath.Base(target))
	}

	repo, err := s.openRepo(target)
	if err != nil {
		return nil, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	// 并发首次查词可能都通过了上面的检查，以先到者为准，后者关掉自己那份。
	if existing, ok := s.opened[target]; ok {
		repo.Close() //nolint:errcheck
		return existing, nil
	}
	s.opened[target] = repo
	return repo, nil
}

// cleanOldCore 删除同目录下其他版本的核心词库。
//
// 只删 en-zh.core.*.db 这一种命名：升级后仍读旧库是这类"版本化文件名"
// 方案唯一的坑，留着旧文件不会立刻出问题，但会让排障时看到两个文件。
func cleanOldCore(dir, keep string) {
	matches, err := filepath.Glob(filepath.Join(dir, "en-zh.core.*.db"))
	if err != nil {
		return
	}
	for _, m := range matches {
		if filepath.Base(m) != keep {
			os.Remove(m) //nolint:errcheck
		}
	}
}

// ── 辅助 ────────────────────────────────────────────────────────

// lookupZhEntries 查汉英库并按拼音去重。
//
// CC-CEDICT 里同一个词条常有「同拼音不同繁体」的多条记录，
// 原样返回会让浮层里出现两行一模一样的释义。
func (s *DictService) lookupZhEntries(ctx context.Context, repo port.DictionaryRepository, word string) ([]dto.DictEntryView, error) {
	entries, err := repo.LookupZh(ctx, word)
	if err != nil {
		return nil, err
	}
	seen := make(map[string]bool, len(entries))
	out := make([]dto.DictEntryView, 0, len(entries))
	for _, e := range entries {
		key := e.Pinyin + "\x00" + e.Translation
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, entryView(e))
	}
	return out, nil
}

func oneEntry(e domain.DictEntry) []dto.DictEntryView {
	return []dto.DictEntryView{entryView(e)}
}

func entryView(e domain.DictEntry) dto.DictEntryView {
	return dto.DictEntryView{
		Word:        e.Word,
		Phonetic:    e.Phonetic,
		Translation: e.Translation,
		Pos:         e.Pos,
		Tags:        e.Tags,
		Collins:     e.Collins,
		Oxford:      e.Oxford,
		BNC:         e.BNC,
		FRQ:         e.FRQ,
		Pinyin:      e.Pinyin,
		Trad:        e.Trad,
	}
}

// variantView 组装「命中的是变形」这种结果。
func variantView(base dto.DictResultView, query, lemma, types, matchedBy string, rule bool, e domain.DictEntry) dto.DictResultView {
	base.MatchedBy = matchedBy
	base.Lemma = lemma
	base.FormLabel = domain.FormLabel(types, query, lemma)
	base.RuleGuess = rule
	base.Entries = oneEntry(e)
	return base
}

// dehyphenate 把连字符替换成空格，并给出粘连写法。
//
// 返回第一个非空且与原词不同的写法；两级都试一遍是因为
// ECDICT 里 `longtime`、`long time`、`long-time` 三种写法各自独立收录。
func dehyphenate(word string) string {
	if strings.ContainsRune(word, '-') {
		return strings.ReplaceAll(word, "-", " ")
	}
	if strings.ContainsRune(word, ' ') {
		return strings.ReplaceAll(word, " ", "")
	}
	return ""
}

// prefixOf 返回用于「你是不是要找」的前缀。
//
// 截掉末尾 2 个字符：拼错的词（perceivd、happines）截断后仍能
// 命中同族词；不截断则前缀查不出任何东西。
func prefixOf(word string) string {
	r := []rune(word)
	if len(r) <= 4 {
		return word
	}
	return string(r[:len(r)-2])
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func (s *DictService) fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}
