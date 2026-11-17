package dto

// PlayURL 是一次播放会话的地址。
//
// URL 形如 "/stream/<sid>.mp3"：真实音频地址与请求头只留在 Go 侧，
// 绝不交给前端。前端直接把它塞给 <audio src>，由 /stream/ 代理负责带
// Referer/Cookie 去取流并透传 Range。每次切章都会换新 sid。
type PlayURL struct {
	URL   string `json:"url"`
	Title string `json:"title"`
	Index int    `json:"index"`
}

// AudioDownloadView 是「下载若干章音频」任务启动后的即时回执。
type AudioDownloadView struct {
	BookID int64 `json:"bookId"`
	Total  int   `json:"total"`
}

// AudioCacheView 描述一章已落盘的离线音频。
type AudioCacheView struct {
	Index int    `json:"index"`
	Size  int64  `json:"size"`
	Path  string `json:"path"`
}

// AudioPlaybackState 是听书的「服务态」镜像。
//
// 真正的播放器在 WebView 的 HTMLAudioElement 里，但宿主（安卓前台 Service、
// 锁屏/通知栏媒体控制）与 Go 业务层都需要一份权威状态：前端每次状态变化上报，
// AudioService 存下快照、分配单调递增的 seq 并广播 audio:playback:state。
// seq 用来丢弃乱序事件，clientId 让上报方忽略自己发出的那一轮广播，避免回环。
//
// 注意这里不含 playUrl：播放地址是一次性会话，绝不能进事件广播。
type AudioPlaybackState struct {
	BookID       int64  `json:"bookId"`
	BookName     string `json:"bookName"`
	ChapterIndex int    `json:"chapterIndex"`
	ChapterTitle string `json:"chapterTitle"`
	Cover        string `json:"cover"`
	// idle | loading | playing | paused | error
	Status     string  `json:"status"`
	PositionMs int     `json:"positionMs"`
	DurationMs int     `json:"durationMs"`
	Rate       float64 `json:"rate"`
	// LIST_END_STOP | SINGLE_LOOP | RANDOM | LIST_LOOP
	PlayMode string `json:"playMode"`
	// ClientID 标识上报方；广播时原样带回，供前端过滤自己的回声。
	ClientID string `json:"clientId"`
	// Seq 由 AudioService 分配，不从前端接受。
	Seq int64 `json:"seq"`
}

// AudioCommand 是原生宿主（媒体键 / 通知栏 / 音频焦点 / 拔耳机）发给前端的指令。
//
// 安卓侧通过 WailsBridge.emitEvent 发 "audio:command"，载荷与这里保持同构；
// Go 侧不参与转发（宿主事件直接进 Wails 事件总线），但保留 DTO 作为契约定义。
type AudioCommand struct {
	// play | pause | toggle | prev | next | stop | seekto | seekbackward | seekforward
	Action string `json:"action"`
	// Value 对 seekto 是毫秒，对 seekbackward / seekforward 是秒。
	Value float64 `json:"value"`
	// Reason 仅用于诊断：media_button | notification | audio_focus | noisy | timer。
	Reason string `json:"reason"`
}

// AudioCacheProgress 是后台下载任务推送给前端的事件载荷。
type AudioCacheProgress struct {
	BookID int64  `json:"bookId"`
	Done   int    `json:"done"`
	Total  int    `json:"total"`
	Index  int    `json:"index"`
	State  string `json:"state"` // running | done | canceled | error
	Error  string `json:"error"`
}
