package dto

// 词典来源。
//
// 必须在界面上显示出来：内置核心 / 完整词库 / 汉英词典 / 在线翻译
// 四种来源的覆盖面与可信度都不同，不标出来用户无法判断
// 「为什么这个词只查到词性没有释义」。
const (
	DictSourceCore   = "core"   // 内置核心词库（top30k）
	DictSourceFull   = "full"   // 完整词库（用户安装）
	DictSourceCedict = "cedict" // 汉英词典（CC-CEDICT）
	DictSourceNone   = "none"   // 未命中
)

// 命中方式。前端据此决定提示语的强度：
// exact 直接展示；form/rule 要说明「这是 xx 的过去式」；
// prefix/single 属于猜测，提示语必须弱化。
const (
	DictMatchExact  = "exact"  // 主表精确命中
	DictMatchForm   = "form"   // 词形表还原命中
	DictMatchRule   = "rule"   // 规则还原命中
	DictMatchPrefix = "prefix" // 前缀猜测
	DictMatchSingle = "single" // 中文单字兜底
	DictMatchNone   = "none"   // 未命中
)

// DictEntryView 是一条词条的前端形态。
type DictEntryView struct {
	Word        string   `json:"word"`
	Phonetic    string   `json:"phonetic,omitempty"`
	Translation string   `json:"translation"`
	Pos         string   `json:"pos,omitempty"`
	Tags        []string `json:"tags,omitempty"`
	Collins     int      `json:"collins,omitempty"`
	Oxford      bool     `json:"oxford,omitempty"`
	BNC         int      `json:"bnc,omitempty"`
	FRQ         int      `json:"frq,omitempty"`
	// Pinyin/Trad 仅汉英词典有。
	Pinyin string `json:"pinyin,omitempty"`
	Trad   string `json:"trad,omitempty"`
	// Note 是这一条的补充说明，例如「按单字给出」。
	Note string `json:"note,omitempty"`
}

// DictResultView 是一次查词的完整结果。
type DictResultView struct {
	// Query 是归一化后的查询词，前端要把它显示出来：
	// 用户选的是 `Perceived`，归一化后是 `perceived`，不说清楚会以为是两回事。
	Query     string `json:"query"`
	Direction string `json:"direction"`
	Source    string `json:"source"`
	// Lemma 非空表示命中的是变体，Entry.Word 才是原型。
	Lemma string `json:"lemma,omitempty"`
	// FormLabel 是变体说明，如「过去式」。
	FormLabel   string          `json:"formLabel,omitempty"`
	MatchedBy   string          `json:"matchedBy"`
	Entries     []DictEntryView `json:"entries"`
	Suggestions []string        `json:"suggestions,omitempty"`
	// Hint 是面向用户的说明（未收录、词典未安装、疑似整句）。
	Hint string `json:"hint,omitempty"`
	// Sentence 标记「这更像一整句」，前端据此把整句翻译入口放到最前。
	Sentence bool `json:"sentence,omitempty"`
	// RuleGuess 标记结果来自规则还原，可信度低于词形表。
	RuleGuess bool `json:"ruleGuess,omitempty"`
}

// DictPackageView 是词库包的状态。
type DictPackageView struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	Entries   int    `json:"entries"`
	Version   string `json:"version"`
	BuiltAt   string `json:"builtAt"`
	Builtin   bool   `json:"builtin"`
	Installed bool   `json:"installed"`
	// DownloadBytes 是安装这个包需要下载的源文件体积；
	// 与 Size 并列给出，用户才知道「下 63 MB 装出 47 MB」。
	DownloadBytes int64 `json:"downloadBytes,omitempty"`
	// SourceLabel 是「来源与许可」那一行的文案。
	SourceLabel string `json:"sourceLabel,omitempty"`
	// Removable 表示界面上可以显示删除。内置核心永远为 false。
	Removable bool `json:"removable"`
}

// DictStatusView 是设置页词典卡片的整体状态。
type DictStatusView struct {
	Packages []DictPackageView `json:"packages"`
	// Ready 表示核心词库已解压可用；为假时查词会返回明确错误。
	Ready bool `json:"ready"`
}

// DictSourceView 是下载源选择器里的一项。
//
// Usable=false 时必须带 Reason 且界面要显示出来：灰掉不解释，
// 用户会以为是软件坏了。
type DictSourceView struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Kind：builtin / custom。
	Kind string `json:"kind"`
	// Note 是常驻说明（例如「实测约 283 KB/s」）。
	Note string `json:"note,omitempty"`
	// Reason 是在**当前包**的上下文里不可用的原因。
	Reason string `json:"reason,omitempty"`
	// Usable 是按包体与托管形态过滤后的结论。
	Usable   bool `json:"usable"`
	Selected bool `json:"selected"`
}

// DictSourceConfigView 是当前下载源配置。
type DictSourceConfigView struct {
	// Mode：auto（依次尝试）/ manual（只用选中源）。
	Mode      string `json:"mode"`
	SourceID  string `json:"sourceId"`
	CustomURL string `json:"customUrl"`
	// CustomKind 是自定义串被识别出的形态（中文说明）。
	CustomKind string   `json:"customKind,omitempty"`
	Order      []string `json:"order"`
	// PreviewURL 是「按当前配置，这个包最终会请求哪个地址」。
	// 设置页要显示它：用户填了前缀还是完整地址，一眼可辨。
	PreviewURL string `json:"previewUrl,omitempty"`
	// PreviewError 非空表示当前配置拼不出可用地址（例如自定义串未填）。
	PreviewError string `json:"previewError,omitempty"`
}

// DictProbeView 是一次源探测的结论。
type DictProbeView struct {
	OK        bool    `json:"ok"`
	URL       string  `json:"url,omitempty"`
	HTTPCode  int     `json:"httpCode,omitempty"`
	KBps      float64 `json:"kbps,omitempty"`
	RangeOK   bool    `json:"rangeOk,omitempty"`
	ElapsedMs int64   `json:"elapsedMs,omitempty"`
	Err       string  `json:"err,omitempty"`
}

// 安装阶段。前端按 phase 决定进度条文案与是否可取消。
const (
	DictPhaseDownload = "download" // 下载源文件
	DictPhaseVerify   = "verify"   // sha256 / 体积校验
	DictPhaseConvert  = "convert"  // 转换成本地词库
	DictPhaseDone     = "done"
	DictPhaseFailed   = "failed"
	DictPhaseCanceled = "canceled"
)

// DictInstallProgress 是扩展包安装的进度事件。
type DictInstallProgress struct {
	PackID string `json:"packId"`
	// Phase 取 download / verify / convert / done / failed / canceled。
	Phase string `json:"phase"`
	// Done/Total 在 download 与 convert 阶段是**字节数**，
	// verify 阶段是 0/100 的百分比占位（哈希无法切片回报）。
	Done  int64 `json:"done"`
	Total int64 `json:"total"`
	// Bytes/TotalBytes 只在 download 阶段有意义，供「12.3 / 63.0 MB」展示。
	Bytes      int64 `json:"bytes"`
	TotalBytes int64 `json:"totalBytes"`
	// SourceID/SourceName 是当前实际使用的源；SwitchedFrom 非空表示
	// 刚从一个失败的源切过来——界面必须明示，不能静默换源。
	SourceID     string `json:"sourceId,omitempty"`
	SourceName   string `json:"sourceName,omitempty"`
	SwitchedFrom string `json:"switchedFrom,omitempty"`
	Message      string `json:"message,omitempty"`
	// Entries 是转换出的词条数，只在 done 阶段有意义。
	Entries int `json:"entries,omitempty"`
	// Seq 是进程内单调递增序号，前端据此丢弃迟到的事件。
	Seq int64 `json:"seq"`
}
