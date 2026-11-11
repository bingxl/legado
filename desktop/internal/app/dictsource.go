package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"

	"github.com/legado/desktop/internal/app/dictdata"
	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// 内置下载源 ID。前端只认这些字符串，改名等于破坏兼容。
const (
	DictSourceIDGitHub   = "github"
	DictSourceIDGhfast   = "ghfast"
	DictSourceIDGhproxy  = "gh-proxy"
	DictSourceIDGhnet    = "ghproxy-net"
	DictSourceIDJsdelivr = "jsdelivr"
	DictSourceIDCustom   = "custom"
	// DictSourceIDAuto 不是真实源，只用于「自动」模式。
	DictSourceIDAuto = "auto"
)

// jsdelivrMaxFile 是 jsDelivr 的单文件硬上限（20 MB）。
//
// 这不是推测：对 63 MB 的 ecdict.csv 实测返回
// `403 File size exceeded the configured limit of 20 MB.`。
// 因此源选择器必须按包体做能力过滤，不能让用户下到 100% 才失败。
const jsdelivrMaxFile = 20 << 20

// dictSource 是一个下载源的静态描述。
type dictSource struct {
	ID   string
	Name string
	// Kind：direct（原样请求）/ prefix（前缀拼接）/ jsdelivr（改写）/ custom（用户填）。
	Kind string
	// Prefix 只有 prefix 形态用。
	Prefix string
	// MaxFile 为 0 表示不限制。
	MaxFile int64
	// Forms 是该源能代理的托管形态（raw / release）。
	Forms []string
	Note  string
}

// builtinSources 是内置源清单。
//
// 顺序不代表优先级——序列在设置里（用户可以调），这里只是展示顺序。
// 各源的实测吞吐与可用性见设计方案 §4.2.1：ghfast / gh-proxy 约 280 KB/s，
// GitHub 直连约 27 KB/s，ghproxy.net 约 24 KB/s；ghp.ci / moeyy / kkgithub
// 实测全部 502，ghps.cc 404，所以它们**不在清单里**——把已知失效的地址
// 摆进下拉框，用户会以为是我们没做好。
func builtinSources() []dictSource {
	return []dictSource{
		{
			ID: DictSourceIDGhfast, Name: "ghfast.top", Kind: "prefix",
			Prefix: "https://ghfast.top/",
			Forms:  []string{"raw", "release"},
			Note:   "实测约 283 KB/s，默认首选",
		},
		{
			ID: DictSourceIDGhproxy, Name: "gh-proxy.com", Kind: "prefix",
			Prefix: "https://gh-proxy.com/",
			Forms:  []string{"raw", "release"},
			Note:   "实测约 276 KB/s",
		},
		{
			ID: DictSourceIDJsdelivr, Name: "jsDelivr", Kind: "jsdelivr",
			MaxFile: jsdelivrMaxFile,
			Forms:   []string{"raw"},
			Note:    "单文件上限 20 MB，仅适用小包",
		},
		{
			ID: DictSourceIDGhnet, Name: "ghproxy.net", Kind: "prefix",
			Prefix: "https://ghproxy.net/",
			Forms:  []string{"raw", "release"},
			Note:   "能通但较慢（约 24 KB/s）",
		},
		{
			ID: DictSourceIDGitHub, Name: "GitHub 直连", Kind: "direct",
			Forms: []string{"raw", "release"},
			Note:  "官方地址，最慢但最少失效，兜底用",
		},
	}
}

// builtinSource 按 ID 取内置源。
func builtinSource(id string) (dictSource, bool) {
	for _, s := range builtinSources() {
		if s.ID == id {
			return s, true
		}
	}
	return dictSource{}, false
}

// ── 源配置（settings 表） ───────────────────────────────────────

// dictSourceSettings 是 `dict.source` 的 JSON 形态。
type dictSourceSettings struct {
	// Mode 取 auto（依次尝试）或 manual（只用选中源，失败即停）。
	Mode      string   `json:"mode"`
	SourceID  string   `json:"sourceId"`
	CustomURL string   `json:"customUrl"`
	Order     []string `json:"order"`
}

// defaultSourceSettings 是首次使用时的配置。
//
// 默认 auto 且把快的源排在前面：用户第一次点下载时不该先经历史上最慢的
// GitHub 直连，也不该被要求先去理解「镜像」是什么。
func defaultSourceSettings() dictSourceSettings {
	return dictSourceSettings{
		Mode:     "auto",
		SourceID: DictSourceIDGhfast,
		Order: []string{
			DictSourceIDGhfast, DictSourceIDGhproxy, DictSourceIDJsdelivr,
			DictSourceIDGhnet, DictSourceIDGitHub,
		},
	}
}

func (s *DictService) loadSourceSettings(ctx context.Context) dictSourceSettings {
	cfg := defaultSourceSettings()
	if s.settings == nil {
		return cfg
	}
	raw, err := s.settings.Get(ctx, port.SettingDictSource)
	if err != nil || strings.TrimSpace(raw) == "" {
		return cfg
	}
	var saved dictSourceSettings
	if err := json.Unmarshal([]byte(raw), &saved); err != nil {
		return cfg
	}
	// 逐项合并而不是整体覆盖：老版本存下的 JSON 缺字段时，
	// 直接用零值会让「顺序」变成空列表，表现在界面上就是源一个都不剩。
	if saved.Mode == "auto" || saved.Mode == "manual" {
		cfg.Mode = saved.Mode
	}
	if saved.SourceID != "" {
		cfg.SourceID = saved.SourceID
	}
	cfg.CustomURL = saved.CustomURL
	if len(saved.Order) > 0 {
		cfg.Order = saved.Order
	}
	return cfg
}

func (s *DictService) persistSourceSettings(ctx context.Context, cfg dictSourceSettings) error {
	if s.settings == nil {
		return domain.ErrNotConfigured
	}
	b, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	return s.settings.Set(ctx, port.SettingDictSource, string(b))
}

// ── URL 拼装 ───────────────────────────────────────────────────

// baseURL 把仓内坐标拼成上游的规范地址（未经镜像改写）。
func baseURL(c dictdata.SourceCoord) (string, error) {
	repo := strings.Trim(strings.TrimSpace(c.Repo), "/")
	ref := strings.TrimSpace(c.Ref)
	p := strings.TrimLeft(strings.TrimSpace(c.Path), "/")
	if repo == "" || ref == "" || p == "" {
		return "", fmt.Errorf("词库清单缺少仓库坐标（repo/ref/path）")
	}
	switch c.Form {
	case "", "raw":
		return fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/%s", repo, ref, p), nil
	case "release":
		return fmt.Sprintf("https://github.com/%s/releases/download/%s/%s", repo, ref, p), nil
	default:
		return "", fmt.Errorf("未知托管形态 %q", c.Form)
	}
}

// assembleURL 按源形态把规范地址改写成实际请求地址。
//
// 三种形态的差异全部收在这里，业务代码只认「包 ID + 源 ID」。
func assembleURL(src dictSource, coord dictdata.SourceCoord, customURL string) (string, error) {
	if src.Kind == "custom" {
		return assembleCustom(customURL, coord)
	}
	base, err := baseURL(coord)
	if err != nil {
		return "", err
	}
	switch src.Kind {
	case "direct":
		return base, nil
	case "prefix":
		return src.Prefix + base, nil
	case "jsdelivr":
		// jsDelivr 只认 raw 形态，且路径是 gh/{repo}@{ref}/{path}。
		repo := strings.Trim(strings.TrimSpace(coord.Repo), "/")
		p := strings.TrimLeft(strings.TrimSpace(coord.Path), "/")
		return fmt.Sprintf("https://cdn.jsdelivr.net/gh/%s@%s/%s", repo, coord.Ref, p), nil
	default:
		return "", fmt.Errorf("未知源形态 %q", src.Kind)
	}
}

// customKind 是自定义串被识别出的形态。
const (
	customDirect   = "direct"   // 指向具体文件
	customPrefix   = "prefix"   // 前缀拼接
	customTemplate = "template" // {url} 占位符替换
)

// parseCustom 识别用户填的地址。
//
// 判定顺序固定为「模板 → 具体文件 → 前缀」，因为：
// 含 {url} 的串不可能是合法 URL（花括号会被转义），先判它没有歧义；
// 具体文件与前缀的差别只在「路径像不像一个文件」，放后面。
func parseCustom(raw string) (kind, value string, err error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", "", fmt.Errorf("请填写自定义地址")
	}
	if strings.Contains(s, "{url}") {
		u, err := url.Parse(strings.ReplaceAll(s, "{url}", "https://example.com/x"))
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
			return "", "", fmt.Errorf("自定义模板必须以 http:// 或 https:// 开头")
		}
		return customTemplate, s, nil
	}
	u, err := url.Parse(s)
	if err != nil {
		return "", "", fmt.Errorf("地址格式不正确: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		// file:// 能读本地任意文件、javascript: 能执行脚本，一律拒绝。
		return "", "", fmt.Errorf("只支持 http:// 与 https:// 地址")
	}
	if u.Host == "" {
		return "", "", fmt.Errorf("地址缺少主机名")
	}
	if looksLikeFile(u.Path) {
		return customDirect, s, nil
	}
	// 前缀形态自动补尾部 /：用户写不写 ghfast.top 还是 ghfast.top/ 都该生效。
	if !strings.HasSuffix(s, "/") {
		s += "/"
	}
	return customPrefix, s, nil
}

// fileExts 是「这看起来是一个文件」的判据。
func fileExts() map[string]bool {
	return map[string]bool{".db": true, ".gz": true, ".csv": true, ".u8": true, ".zip": true, ".txt": true}
}

func looksLikeFile(p string) bool {
	return fileExts()[strings.ToLower(path.Ext(p))]
}

// assembleCustom 按识别出的形态拼出请求地址。
func assembleCustom(raw string, coord dictdata.SourceCoord) (string, error) {
	kind, value, err := parseCustom(raw)
	if err != nil {
		return "", err
	}
	if kind == customDirect {
		return value, nil
	}
	base, err := baseURL(coord)
	if err != nil {
		return "", err
	}
	if kind == customTemplate {
		// 不做 URL 编码：镜像要求原样嵌套，编码后反而 404。
		return strings.ReplaceAll(value, "{url}", base), nil
	}
	return value + base, nil
}

// customKindLabel 给界面用的中文说明。
func customKindLabel(kind string) string {
	switch kind {
	case customDirect:
		return "完整文件地址（直接使用）"
	case customPrefix:
		return "前缀镜像（自动拼接上游地址）"
	case customTemplate:
		return "{url} 模板（替换为上游地址）"
	default:
		return ""
	}
}

// ── 面向界面的源列表 ───────────────────────────────────────────

// SourcesFor 返回针对指定包过滤后的源列表。
//
// usable=false 的源仍要返回并带上 reason：直接灰掉不解释，用户会以为
// 是软件坏了；告诉他「jsDelivr 单文件上限 20 MB，本包 63 MB」才可行动。
func (s *DictService) SourcesFor(ctx context.Context, packID string) ([]dto.DictSourceView, error) {
	pack, ok := dictdata.ExtPack(packID)
	if !ok {
		return nil, fmt.Errorf("未知的词库包 %q", packID)
	}
	cfg := s.loadSourceSettings(ctx)
	coord := pack.Source

	out := make([]dto.DictSourceView, 0, len(builtinSources())+1)
	appendOne := func(src dictSource) {
		v := dto.DictSourceView{
			ID:   src.ID,
			Name: src.Name,
			Kind: "builtin",
			Note: src.Note,
		}
		if reason := capacityReason(src, coord); reason != "" {
			v.Reason = reason
		} else {
			v.Usable = true
		}
		v.Selected = cfg.SourceID == src.ID
		out = append(out, v)
	}
	// 按用户配置的顺序输出，未列进顺序的源补在后面。
	seen := map[string]bool{}
	for _, id := range cfg.Order {
		if src, ok := builtinSource(id); ok && !seen[id] {
			appendOne(src)
			seen[id] = true
		}
	}
	for _, src := range builtinSources() {
		if !seen[src.ID] {
			appendOne(src)
			seen[src.ID] = true
		}
	}

	custom := dto.DictSourceView{
		ID:     DictSourceIDCustom,
		Name:   "自定义…",
		Kind:   "custom",
		Note:   "自建反代 / 内网分发 / 已下载的文件",
		Usable: true,
		// 自定义串填错时才不可用：这里只做静态判定，
		// 真正的可用性要靠测速。
		Selected: cfg.SourceID == DictSourceIDCustom,
	}
	if cfg.CustomURL != "" {
		if kind, _, err := parseCustom(cfg.CustomURL); err != nil {
			custom.Usable = false
			custom.Reason = err.Error()
		} else {
			custom.Note = customKindLabel(kind)
		}
	}
	out = append(out, custom)
	return out, nil
}

// capacityReason 判断某个源能不能承载这个包；能用返回空串。
func capacityReason(src dictSource, coord dictdata.SourceCoord) string {
	form := coord.Form
	if form == "" {
		form = "raw"
	}
	if len(src.Forms) > 0 && !contains(src.Forms, form) {
		return fmt.Sprintf("该源不支持 %s 形态的托管", form)
	}
	if src.MaxFile > 0 && coord.Size > src.MaxFile {
		return fmt.Sprintf(
			"单文件上限 %s，本包需下载 %s，无法使用",
			formatMB(src.MaxFile), formatMB(coord.Size),
		)
	}
	return ""
}

func contains(list []string, v string) bool {
	for _, s := range list {
		if s == v {
			return true
		}
	}
	return false
}

// formatMB 把字节数格式化成「63.0 MB」或「8.6 MB」。
func formatMB(n int64) string {
	if n < 1<<20 {
		return fmt.Sprintf("%.0f KB", float64(n)/1024)
	}
	return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
}

// SourceConfig 返回当前源配置，并用指定包回显「最终会请求哪个地址」。
//
// 回显是防「填了却生效成另一种意思」的关键：用户填 https://ghfast.top
// 之后要能一眼看到最终 URL 长什么样。
func (s *DictService) SourceConfig(ctx context.Context, packID string) (dto.DictSourceConfigView, error) {
	cfg := s.loadSourceSettings(ctx)
	out := dto.DictSourceConfigView{
		Mode:      cfg.Mode,
		SourceID:  cfg.SourceID,
		CustomURL: cfg.CustomURL,
		Order:     cfg.Order,
	}
	if kind, _, err := parseCustom(cfg.CustomURL); err == nil {
		out.CustomKind = customKindLabel(kind)
	}
	if packID == "" {
		return out, nil
	}
	pack, ok := dictdata.ExtPack(packID)
	if !ok {
		return out, fmt.Errorf("未知的词库包 %q", packID)
	}
	src, ok := builtinSource(cfg.SourceID)
	if cfg.SourceID == DictSourceIDCustom {
		src = dictSource{ID: DictSourceIDCustom, Kind: "custom"}
	} else if !ok {
		src, _ = builtinSource(DictSourceIDGhfast)
	}
	if u, err := assembleURL(src, pack.Source, cfg.CustomURL); err == nil {
		out.PreviewURL = u
	} else {
		out.PreviewError = err.Error()
	}
	return out, nil
}

// Preview 返回「按这组配置，这个包最终会请求哪个地址」。
//
// 设置页每改一次源就要回显一次，所以这里只做字符串拼装、**不发请求**。
// 与 SourceConfig 的区别：那个读的是已保存的配置，这个是「还没保存时的预演」。
func (s *DictService) Preview(_ context.Context, packID, sourceID, customURL string) (dto.DictSourceConfigView, error) {
	pack, ok := dictdata.ExtPack(packID)
	if !ok {
		return dto.DictSourceConfigView{}, fmt.Errorf("未知的词库包 %q", packID)
	}
	out := dto.DictSourceConfigView{SourceID: sourceID, CustomURL: customURL}
	if kind, _, err := parseCustom(customURL); err == nil {
		out.CustomKind = customKindLabel(kind)
	}
	var src dictSource
	if sourceID == DictSourceIDCustom {
		src = dictSource{ID: DictSourceIDCustom, Kind: "custom"}
	} else if s, ok := builtinSource(sourceID); ok {
		src = s
	} else {
		out.PreviewError = "未知的下载源"
		return out, nil
	}
	u, err := assembleURL(src, pack.Source, customURL)
	if err != nil {
		out.PreviewError = err.Error()
		return out, nil
	}
	out.PreviewURL = u
	return out, nil
}

// SetSource 保存源配置。
//
// 只校验「源 ID 是不是已知的」与「自定义串能不能解析」，**不做连通性校验**：
// 保存配置不该依赖网络可用，测速是单独的显式动作。
func (s *DictService) SetSource(ctx context.Context, mode, sourceID, customURL string) error {
	if mode != "" && mode != "auto" && mode != "manual" {
		return fmt.Errorf("模式只能是 auto 或 manual")
	}
	if sourceID != "" && sourceID != DictSourceIDCustom {
		if _, ok := builtinSource(sourceID); !ok {
			return fmt.Errorf("未知的下载源 %q", sourceID)
		}
	}
	customURL = strings.TrimSpace(customURL)
	if customURL != "" {
		if _, _, err := parseCustom(customURL); err != nil {
			return err
		}
	}
	if sourceID == DictSourceIDCustom && customURL == "" {
		return fmt.Errorf("选择「自定义」时必须填写地址")
	}

	cfg := s.loadSourceSettings(ctx)
	if mode != "" {
		cfg.Mode = mode
	}
	if sourceID != "" {
		cfg.SourceID = sourceID
	}
	cfg.CustomURL = customURL
	return s.persistSourceSettings(ctx, cfg)
}

// ── 测速 ───────────────────────────────────────────────────────

// probeTimeout 是单次探测的总超时。
const probeTimeout = 12 * time.Second

// probeBytes 是探测请求的字节数（64 KB）。
//
// 取 64 KB 而不是 1 KB：太小会被 TLS 握手与首包延迟主导，
// 测出来的速度全是噪声，用户按这个选源会选错。
const probeBytes = 64 << 10

// Probe 对指定源做一次 Range 探测。
//
// 服务端**不缓存**结果：镜像的可用性按小时变化，缓存一个「上次还快」
// 的结论比不测更糟。前端也只在本次会话内保留测速值。
func (s *DictService) Probe(ctx context.Context, packID, sourceID, customURL string) (dto.DictProbeView, error) {
	pack, ok := dictdata.ExtPack(packID)
	if !ok {
		return dto.DictProbeView{}, fmt.Errorf("未知的词库包 %q", packID)
	}
	var src dictSource
	if sourceID == DictSourceIDCustom {
		src = dictSource{ID: DictSourceIDCustom, Kind: "custom"}
	} else {
		var ok bool
		if src, ok = builtinSource(sourceID); !ok {
			return dto.DictProbeView{}, fmt.Errorf("未知的下载源 %q", sourceID)
		}
		if reason := capacityReason(src, pack.Source); reason != "" {
			// 能力不满足时不必发请求：结论已经确定，发请求只会让人以为还有希望。
			return dto.DictProbeView{OK: false, Err: reason}, nil
		}
	}
	target, err := assembleURL(src, pack.Source, customURL)
	if err != nil {
		return dto.DictProbeView{OK: false, Err: err.Error()}, nil
	}

	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return dto.DictProbeView{OK: false, Err: "地址无法请求：" + err.Error()}, nil
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=0-%d", probeBytes-1))
	req.Header.Set("User-Agent", dictUserAgent)

	start := time.Now()
	resp, err := http.DefaultClient.Do(req)
	elapsed := time.Since(start)
	out := dto.DictProbeView{URL: target, ElapsedMs: elapsed.Milliseconds()}
	if err != nil {
		out.Err = "连接失败：" + err.Error()
		return out, nil
	}
	defer resp.Body.Close() //nolint:errcheck
	out.HTTPCode = resp.StatusCode

	n, _ := io.Copy(io.Discard, io.LimitReader(resp.Body, probeBytes))
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
		out.Err = fmt.Sprintf("服务端返回 %d", resp.StatusCode)
		return out, nil
	}
	// 206 且长度等于请求长度才算真正支持断点续传。
	out.RangeOK = resp.StatusCode == http.StatusPartialContent && n == probeBytes
	secs := elapsed.Seconds()
	if secs > 0 {
		out.KBps = float64(n) / 1024 / secs
	}
	out.OK = out.HTTPCode == http.StatusOK || out.HTTPCode == http.StatusPartialContent
	if out.OK && !out.RangeOK {
		out.Err = "服务端不支持断点续传，下载中断需重新开始"
	}
	return out, nil
}

// dictUserAgent 是所有词库下载请求的 UA。
//
// 带上应用名而不是默认的 Go-http-client：镜像站排查流量时能看懂来源，
// 也方便日后按 UA 做限流或白名单。
const dictUserAgent = "legado-desktop/dict-installer"
