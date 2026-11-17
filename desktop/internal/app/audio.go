// Package app 的听书用例：音频地址解析、同域流式代理与离线下载。
//
// 对齐 Kotlin 原版的分工：AudioPlay.kt 把 WebBook.getContent 的结果当作
// 「播放地址规则串」，AudioPlayService 用 AnalyzeUrl 展开 URL 选项/请求头后
// 交给 ExoPlayer。桌面端把「展开」放在 adapter/legado（AudioResolver），
// 把「播放器」放在前端 HTMLAudioElement，本服务负责中间的会话化代理：
//
//	真实 URL + 请求头  →  /stream/<sid>.mp3  →  WebView <audio src>
//
// 真实地址与凭据绝不落地前端：音频站普遍校验 Referer/Cookie/Authorization，
// 直接把 URL 交给 WebView 会 403，也会把登录态暴露给页面脚本。
package app

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// AudioRoutePrefix 是音频流的路由前缀。
//
// 用 /stream/ 而不是 /audio/：前端播放页自己就是 /audio/:id，两者共用前缀时
// 整页刷新（F5）会把播放页深链当成音频请求交给代理，直接白屏。
const AudioRoutePrefix = "/stream/"

// AudioMetaRoutePrefix 供安卓宿主取播放会话元数据。
//
// 安卓的 WailsPathHandler 用 bridge.serveAsset() 把整个响应读成 byte[] 再交给
// WebView，既不支持流式也不支持 Range —— 音频不能走这条路。Java 侧改为拦截
// /stream/ 后从这个端点取「真实 URL + 请求头」，自己用 HttpURLConnection
// 流式请求并透传 206。桌面端不需要，但端点开着也只在本应用内部可达。
const AudioMetaRoutePrefix = "/streammeta/"

const (
	// maxAudioSessions 限制跨书同时保留的会话总量。
	maxAudioSessions = 24
	// audioSessionIdleTTL 是滑动有效期：每次 Range / 元数据请求都会续期，
	// 停播 6 小时后会话自动失效，避免凭据长期驻留内存。
	audioSessionIdleTTL = 6 * time.Hour
	// audioSessionMaxTTL 是绝对上限：即使一直在听，24 小时后也必须重新解析。
	// 音频直链普遍带时效签名，会话本身不能比签名活得更久。
	audioSessionMaxTTL = 24 * time.Hour
)

// AudioDeps 是听书服务的依赖，由组合根注入。
type AudioDeps struct {
	Root     string
	Books    port.BookRepository
	Chapters port.ChapterRepository
	Sources  port.BookSourceRepository
	// Vars 是书源自定义变量存储。默认音频源的规则会读 source.getVariable()，
	// 和搜索/详情页一样必须先把变量挂到书源实体上，否则解析出的地址会缺参数。
	Vars     port.SourceVariableRepository
	Resolver port.AudioResolver
	Events   port.EventBus
	Client   *http.Client
}

// audioSession 是一次播放会话。LocalPath 非空时表示命中离线缓存，
// 此时不再访问网络，http.ServeFile 天然支持 Range。
//
// sid 是一次性 nonce：同一本书重新点播时旧会话立即失效，
// createdAt / lastSeen 负责绝对与滑动过期（见 lookupSession）。
type audioSession struct {
	URL       string
	Headers   map[string]string
	LocalPath string
	Ext       string
	BookID    int64
	Index     int
	createdAt time.Time
	lastSeen  time.Time
}

// AudioService 是听书用例，同时实现 /stream/ 与 /streammeta/ 的 http.Handler。
type AudioService struct {
	root     string
	books    port.BookRepository
	chapters port.ChapterRepository
	sources  port.BookSourceRepository
	vars     port.SourceVariableRepository
	resolver port.AudioResolver
	events   port.EventBus
	client   *http.Client
	// directClient 是不走系统代理的直连客户端，作为代理把媒体请求搞挂时的回退。
	//
	// 背景：音频直链（网易云 m*.music.126.net 等）都是公网地址，本不需要代理。
	// 但国内常见的代理 / VPN 类工具会把 HTTP_PROXY 写进环境变量，Go 的
	// http.ProxyFromEnvironment 会忠实地把媒体请求也塞进代理；部分代理会拦截、
	// 改写甚至直接拒掉 Go 客户端（原版阅读 App 走平台网络栈不受影响，所以同一
	// 个网易源在原 legado 里能放、在 legado-go 里报「加载资源失败」）。
	// 因此策略是：先走用户配置的代理（保留需要代理的书源），一旦代理返回错误
	// 或 4xx/5xx，就用 directClient 直连再试一次，自动从「代理把媒体搞挂」里恢复。
	directClient *http.Client

	mu       sync.Mutex
	sessions map[string]*audioSession
	jobs     map[int64]*audioDownloadJob

	// 播放态镜像与播放会话/下载任务无关，单独加锁避免高频 timeupdate
	// 去争用 /stream/ 的会话锁。
	stateMu     sync.Mutex
	playback    dto.AudioPlaybackState
	playbackSeq int64
}

// NewAudioService 构造听书服务。
func NewAudioService(d AudioDeps) *AudioService {
	client := d.Client
	if client == nil {
		client = &http.Client{
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				ResponseHeaderTimeout: 30 * time.Second,
				// 音频不会被 gzip，自动解压反而会让 Content-Length 与实际字节数不符。
				DisableCompression:  true,
				MaxIdleConnsPerHost: 4,
			},
		}
	}
	// 直连客户端：与上游 client 配置一致，但显式关闭系统代理。
	directClient := &http.Client{
		Transport: &http.Transport{
			Proxy:                 nil,
			ResponseHeaderTimeout: 30 * time.Second,
			DisableCompression:    true,
			MaxIdleConnsPerHost:   4,
		},
	}

	return &AudioService{
		root:         d.Root,
		books:        d.Books,
		chapters:     d.Chapters,
		sources:      d.Sources,
		vars:         d.Vars,
		resolver:     d.Resolver,
		events:       d.Events,
		client:       client,
		directClient: directClient,
		sessions:     make(map[string]*audioSession),
		jobs:         make(map[int64]*audioDownloadJob),
	}
}

var _ http.Handler = (*AudioService)(nil)

// ReportPlaybackState 接收前端上报的播放态，存下快照并广播服务态事件。
//
// 对应原版 AudioPlayService 的状态广播：宿主、其他窗口或未来的原生控制器
// 都能拿到同一份权威状态。Seq 由服务端分配，客户端传来的值一律忽略；
// 播放地址不在这里出现，避免一次性的 /stream/ 会话被广播出去。
func (s *AudioService) ReportPlaybackState(ctx context.Context, st dto.AudioPlaybackState) (dto.AudioPlaybackState, error) {
	if st.BookID < 0 || st.ChapterIndex < 0 || st.PositionMs < 0 || st.DurationMs < 0 {
		return dto.AudioPlaybackState{}, fmt.Errorf("%w: 播放状态参数不合法", domain.ErrInvalidArgument)
	}
	switch st.Status {
	case "idle", "loading", "playing", "paused", "error":
	default:
		return dto.AudioPlaybackState{}, fmt.Errorf("%w: 未知播放状态 %q", domain.ErrInvalidArgument, st.Status)
	}
	if st.Status == "idle" {
		// 停止时清空书籍信息，别让通知栏还挂着上一本书。
		st = dto.AudioPlaybackState{Status: "idle", ClientID: st.ClientID}
	}
	s.stateMu.Lock()
	s.playbackSeq++
	st.Seq = s.playbackSeq
	s.playback = st
	s.stateMu.Unlock()

	if s.events != nil {
		if err := s.events.Emit(ctx, port.EventAudioPlaybackState, st); err != nil {
			// 事件总线故障不影响播放本身，也不应该让前端动作失败。
			return st, nil
		}
	}
	return st, nil
}

// PlaybackState 返回当前服务态快照，供冷启动/宿主查询。
func (s *AudioService) PlaybackState() dto.AudioPlaybackState {
	s.stateMu.Lock()
	defer s.stateMu.Unlock()
	return s.playback
}

// chapterFor 取章节并校验书籍确实是音频书，避免把文本书误送进播放器。
func (s *AudioService) chapterFor(ctx context.Context, bookID int64, index int) (*domain.Book, *domain.BookChapter, error) {
	book, err := s.books.Get(ctx, bookID)
	if err != nil {
		return nil, nil, fmt.Errorf("找不到书籍: %w", err)
	}
	if !book.IsAudio() {
		return nil, nil, fmt.Errorf("%w: 这本书不是音频书，请用阅读器打开", domain.ErrInvalidArgument)
	}
	ch, err := s.chapters.Get(ctx, bookID, index)
	if err != nil {
		return nil, nil, fmt.Errorf("找不到第 %d 章: %w", index, err)
	}
	return book, ch, nil
}

// resolveResource 按章展开真实音频地址。
//
// 每次切章/单曲循环/换源都必须重新调用：音频直链普遍带时效签名，
// 原版 AudioPlay.resetData/playPositionChanged 也会清空 durPlayUrl。
func (s *AudioService) resolveResource(ctx context.Context, book *domain.Book, ch *domain.BookChapter) (*port.AudioResource, error) {
	if s.resolver == nil {
		return nil, fmt.Errorf("%w: 未配置音频解析器", domain.ErrNotConfigured)
	}
	src, err := s.sources.FindByURL(ctx, book.Origin)
	if err != nil {
		return nil, fmt.Errorf("找不到该书所属书源: %w", err)
	}
	// 与 SourceService.loadSource 保持一致：书源变量是 JS 的可选输入，
	// 读不到时静默当作没设过，不能让整次播放失败。
	if s.vars != nil {
		if v, err := s.vars.Get(ctx, src.URL); err == nil {
			src.Variable = v
		}
	}
	next := ""
	if n, err := s.chapters.Get(ctx, book.ID, ch.Index+1); err == nil {
		next = n.URL
	}
	res, err := s.resolver.ResolveAudio(ctx, src, book, ch, next)
	if err != nil {
		return nil, err
	}
	if res == nil || strings.TrimSpace(res.URL) == "" {
		return nil, fmt.Errorf("%w: 音频地址解析结果为空", domain.ErrNotFound)
	}
	return res, nil
}

// ResolvePlayURL 为一章创建新的播放会话并返回前端可用的同域地址。
//
// 离线缓存优先：已下载的章节不再联网，直接由本地文件提供（含 Range）。
func (s *AudioService) ResolvePlayURL(ctx context.Context, bookID int64, index int) (*dto.PlayURL, error) {
	if index < 0 {
		return nil, fmt.Errorf("%w: 章节序号不能为负", domain.ErrInvalidArgument)
	}
	book, ch, err := s.chapterFor(ctx, bookID, index)
	if err != nil {
		return nil, err
	}

	sess := &audioSession{BookID: bookID, Index: index}
	if p := s.cachedPath(bookID, index); p != "" {
		sess.LocalPath = p
		sess.Ext = filepath.Ext(p)
	} else {
		res, err := s.resolveResource(ctx, book, ch)
		if err != nil {
			return nil, err
		}
		sess.URL = res.URL
		sess.Headers = res.Headers
		sess.Ext = audioExt(res.URL)
	}
	sid := s.addSession(sess)
	return &dto.PlayURL{
		URL:   AudioRoutePrefix + sid + sess.Ext,
		Title: ch.Title,
		Index: index,
	}, nil
}

func (s *AudioService) addSession(sess *audioSession) string {
	buf := make([]byte, 16)
	var sid string
	if _, err := rand.Read(buf); err == nil {
		sid = hex.EncodeToString(buf)
	} else {
		// 极端情况退化为时间戳，仍然不与现有 sid 冲突。
		sid = fmt.Sprintf("%x", time.Now().UnixNano())
	}
	now := time.Now()
	sess.createdAt, sess.lastSeen = now, now

	s.mu.Lock()
	defer s.mu.Unlock()
	// sid 是 nonce：切章 / 循环 / 换源都会重新 ResolvePlayURL，
	// 同一本书只保留最后一个会话，旧真实 URL 与 Authorization 立即作废。
	// 往回切章时前端同样会重新解析，不需要旧 sid 活着。
	for id, old := range s.sessions {
		if old.BookID == sess.BookID {
			delete(s.sessions, id)
		}
	}
	s.pruneLocked(now)
	s.sessions[sid] = sess
	// 兜底：跨书保留上限，按最近访问时间淘汰最久没用过的会话。
	for len(s.sessions) > maxAudioSessions {
		var oldestSID string
		var oldest time.Time
		for id, cur := range s.sessions {
			if id == sid {
				continue
			}
			if oldest.IsZero() || cur.lastSeen.Before(oldest) {
				oldestSID, oldest = id, cur.lastSeen
			}
		}
		if oldestSID == "" {
			break
		}
		delete(s.sessions, oldestSID)
	}
	return sid
}

// pruneLocked 清掉超过绝对上限或闲置过久的会话；调用方持有 s.mu。
func (s *AudioService) pruneLocked(now time.Time) {
	for sid, sess := range s.sessions {
		if sessionExpired(sess, now) {
			delete(s.sessions, sid)
		}
	}
}

func sessionExpired(sess *audioSession, now time.Time) bool {
	return now.Sub(sess.createdAt) >= audioSessionMaxTTL ||
		now.Sub(sess.lastSeen) >= audioSessionIdleTTL
}

func (s *AudioService) lookupSession(sid string) *audioSession {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess := s.sessions[sid]
	if sess == nil {
		return nil
	}
	now := time.Now()
	if sessionExpired(sess, now) {
		delete(s.sessions, sid)
		return nil
	}
	sess.lastSeen = now // 滑动续期：连续听书不会中途掉线
	return sess
}

// ServeHTTP 提供 /stream/<sid>[.ext] 与 /streammeta/<sid>。
//
// 参数是路径段而非查询串：安卓宿主 WebViewAssetLoader.PathHandler 会把
// 查询串丢掉（见 asset_url.go），写成 ?u= 在安卓端只会拿到空值。
func (s *AudioService) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "只支持 GET/HEAD", http.StatusMethodNotAllowed)
		return
	}
	if strings.HasPrefix(r.URL.Path, AudioMetaRoutePrefix) {
		s.serveMeta(w, r)
		return
	}
	sess := s.lookupSession(audioSID(r.URL.Path, AudioRoutePrefix))
	if sess == nil {
		http.Error(w, "播放会话已失效，请重新点播", http.StatusGone)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if sess.LocalPath != "" {
		// http.ServeFile 自带 Range / 206 / Content-Type 嗅探，离线拖动靠它。
		http.ServeFile(w, r, sess.LocalPath)
		return
	}
	s.proxyAudio(w, r, sess)
}

// audioSID 从 "/stream/<sid>.mp3" 之类的路径里取出 sid，去掉末尾扩展名。
func audioSID(path, prefix string) string {
	rest := strings.TrimPrefix(path, prefix)
	if i := strings.LastIndexByte(rest, '.'); i > 0 {
		return rest[:i]
	}
	return rest
}

// serveMeta 把会话的真实地址与请求头交给安卓宿主。
//
// 只返回元数据、不返回音频字节，所以走 bridge.serveAsset 的 byte[] 通道没有
// 内存问题；Java 侧拿到后自行发起流式请求（见 MainActivity.serveAudioStream）。
func (s *AudioService) serveMeta(w http.ResponseWriter, r *http.Request) {
	sess := s.lookupSession(audioSID(r.URL.Path, AudioMetaRoutePrefix))
	if sess == nil {
		http.Error(w, "播放会话已失效", http.StatusGone)
		return
	}
	type metaView struct {
		URL     string            `json:"url"`
		File    string            `json:"file,omitempty"`
		Headers map[string]string `json:"headers,omitempty"`
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(metaView{
		URL:     sess.URL,
		File:    sess.LocalPath,
		Headers: sess.Headers,
	})
}

// proxyAudio 把上游音频流原样转发，并透传 Range 所需的状态与头。
//
// 兜底策略见 directClient 字段注释：先走（可能带系统代理的）client，失败再直连。
func (s *AudioService) proxyAudio(w http.ResponseWriter, r *http.Request, sess *audioSession) {
	method := http.MethodGet
	if r.Method == http.MethodHead {
		method = http.MethodHead
	}

	req, err := s.buildAudioRequest(r, method, sess)
	if err != nil {
		http.Error(w, "音频请求构造失败", http.StatusBadGateway)
		return
	}
	resp, err := s.client.Do(req)
	// 代理把媒体请求搞挂（连接错误、4xx/5xx，或 200 但被换成了 HTML
	// 拦截页/防盗链页）时，回退直连再试一次。
	if err != nil || unusableAudioResponse(resp) {
		reason := "connection"
		if resp != nil {
			reason = fmt.Sprintf("status=%d type=%q", resp.StatusCode, resp.Header.Get("Content-Type"))
			resp.Body.Close() //nolint:errcheck
		} else if err != nil {
			reason = err.Error()
		}
		req2, e2 := s.buildAudioRequest(r, method, sess)
		if e2 != nil {
			http.Error(w, "音频源连接失败", http.StatusBadGateway)
			return
		}
		resp2, e2 := s.directClient.Do(req2)
		if e2 != nil {
			slog.Warn("音频直连回退失败", "url", loggableAudioURL(sess.URL), "proxy_reason", reason, "err", e2.Error())
			http.Error(w, "音频源连接失败（直连回退）", http.StatusBadGateway)
			return
		}
		slog.Warn("音频代理请求失败，已回退直连", "url", loggableAudioURL(sess.URL), "proxy_reason", reason,
			"direct_status", resp2.StatusCode)
		resp = resp2
	}
	defer resp.Body.Close() //nolint:errcheck

	for _, k := range []string{
		"Content-Type", "Content-Length", "Content-Range",
		"Accept-Ranges", "ETag", "Last-Modified",
	} {
		if v := resp.Header.Get(k); v != "" {
			w.Header().Set(k, v)
		}
	}
	if w.Header().Get("Accept-Ranges") == "" {
		w.Header().Set("Accept-Ranges", "bytes")
	}
	w.WriteHeader(resp.StatusCode)
	if method == http.MethodHead {
		return
	}
	_, _ = io.Copy(w, resp.Body)
}

// buildAudioRequest 构造转发到上游音频地址的请求，并把书源解析阶段给出的头
// 与浏览器兜底头合并。Host / Content-Length 由 http 自动管理，不手动设置。
func (s *AudioService) buildAudioRequest(r *http.Request, method string, sess *audioSession) (*http.Request, error) {
	req, err := http.NewRequestWithContext(r.Context(), method, sess.URL, nil)
	if err != nil {
		return nil, err
	}
	// 浏览器级兜底：个别书源没在规则里带 UA / Accept 时，也别以
	// Go-http-client 暴露给 CDN（部分站点据此拒流）；Referer 缺失则按源域名补。
	if !hasHeaderCI(sess.Headers, "User-Agent") {
		req.Header.Set("User-Agent", DefaultAudioUserAgent)
	}
	if !hasHeaderCI(sess.Headers, "Accept") {
		req.Header.Set("Accept", "*/*")
	}
	if !hasHeaderCI(sess.Headers, "Referer") {
		if u, perr := url.Parse(sess.URL); perr == nil && u.Host != "" {
			req.Header.Set("Referer", u.Scheme+"://"+u.Host+"/")
		}
	}
	for k, v := range sess.Headers {
		if strings.EqualFold(k, "Host") || strings.EqualFold(k, "Content-Length") {
			continue
		}
		req.Header.Set(k, v)
	}
	if v := r.Header.Get("Range"); v != "" {
		req.Header.Set("Range", v)
	}
	if v := r.Header.Get("If-Range"); v != "" {
		req.Header.Set("If-Range", v)
	}
	return req, nil
}

// DefaultAudioUserAgent 是音频代理在书源未提供 UA 时的兜底值。
//
// 与 bootstrap.DefaultUserAgent 保持一致（桌面 Chrome），避免不同默认值造成
// 抓取与播放行为不一致；这里单独定义以避免 audio 包反向依赖 bootstrap。
const DefaultAudioUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

// hasHeaderCI 忽略大小写判断 map 里是否已存在某请求头：书源里 referer / Referer
// 混写很常见，只用下标判断会补出一个重复头。
func hasHeaderCI(headers map[string]string, key string) bool {
	for k := range headers {
		if strings.EqualFold(k, key) {
			return true
		}
	}
	return false
}

// unusableAudioResponse 判断上游响应是否压根不是音频，需要换直连重试。
//
// 两类：4xx/5xx（代理拦截、防盗链 403）；以及 200 但 Content-Type 是 HTML ——
// 常见于代理/网关把请求换成了错误页或登录页，直接透传会让 <audio> 报
// MEDIA_ERR_NETWORK（前端显示「音频加载失败」）。
func unusableAudioResponse(resp *http.Response) bool {
	if resp == nil {
		return true
	}
	if resp.StatusCode >= 400 {
		return true
	}
	ct := strings.ToLower(resp.Header.Get("Content-Type"))
	return strings.Contains(ct, "text/html")
}

// loggableAudioURL 去掉 query 后再写日志。音频直链普遍把时效签名放在 query
// （网易云是 vuutv=…），完整 URL 不适合落到 app.log。
func loggableAudioURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return "<invalid>"
	}
	u.RawQuery = ""
	u.Fragment = ""
	return u.String()
}

// audioExt 从真实地址取扩展名。安卓宿主按路径扩展名决定 Content-Type，
// 取不到时退回 .mp3（大多数音频源都是 mp3）。
func audioExt(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return ".mp3"
	}
	ext := strings.ToLower(filepath.Ext(u.Path))
	switch ext {
	case ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".oga", ".opus",
		".wav", ".webm", ".mp4", ".m4b", ".3gp", ".ts":
		return ext
	default:
		return ".mp3"
	}
}
