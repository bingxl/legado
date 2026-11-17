package app

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// audioEventBus 记录最后一个广播事件，验证服务态快照确实进了事件总线。
type audioEventBus struct {
	port.EventBus
	name    string
	payload any
}

func (b *audioEventBus) Emit(_ context.Context, name string, payload any) error {
	b.name = name
	b.payload = payload
	return nil
}

// 只实现被测路径真正用到的方法，其余靠嵌入接口占位。
type audioBookRepo struct {
	port.BookRepository
	book *domain.Book
}

func (r *audioBookRepo) Get(_ context.Context, id int64) (*domain.Book, error) {
	// 复制一份并回填 id：跨书会话测试要用不同的 bookID。
	cp := *r.book
	cp.ID = id
	return &cp, nil
}

type audioChapterRepo struct {
	port.ChapterRepository
	ch *domain.BookChapter
}

func (r *audioChapterRepo) Get(context.Context, int64, int) (*domain.BookChapter, error) {
	return r.ch, nil
}
func (r *audioChapterRepo) List(context.Context, int64) ([]*domain.BookChapter, error) {
	return []*domain.BookChapter{r.ch}, nil
}

type audioSourceRepo struct{ port.BookSourceRepository }

func (r *audioSourceRepo) FindByURL(context.Context, string) (*domain.BookSource, error) {
	return &domain.BookSource{URL: "https://src.example", Raw: `{"bookSourceType":1}`}, nil
}

// audioVarRepo 模拟书源自定义变量存储。
type audioVarRepo struct {
	port.SourceVariableRepository
	v string
}

func (r *audioVarRepo) Get(context.Context, string) (string, error) { return r.v, nil }

// audioResolverStub 记录传进来的书源变量，用于验证听书链路是否挂了源变量。
type audioResolverStub struct {
	res          *port.AudioResource
	seenVariable string
}

func (s *audioResolverStub) ResolveAudio(_ context.Context, src *domain.BookSource, _ *domain.Book, _ *domain.BookChapter, _ string) (*port.AudioResource, error) {
	if src != nil {
		s.seenVariable = src.Variable
	}
	return s.res, nil
}

func newAudioFixture(root string, res *port.AudioResource, vars ...port.SourceVariableRepository) *AudioService {
	var v port.SourceVariableRepository
	if len(vars) > 0 {
		v = vars[0]
	}
	return NewAudioService(AudioDeps{
		Root: root,
		Books: &audioBookRepo{book: &domain.Book{
			ID:     7,
			Name:   "测试听书",
			Origin: "https://src.example",
			Type:   domain.BookTypeAudio,
			Format: domain.BookFormatAudio,
		}},
		Chapters: &audioChapterRepo{ch: &domain.BookChapter{
			BookID: 7, Index: 2, Title: "第二章", URL: "https://src.example/ch/2",
		}},
		Sources:  &audioSourceRepo{},
		Vars:     v,
		Resolver: &audioResolverStub{res: res},
	})
}

func TestResolvePlayURLReturnsStreamSession(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("X-Token"); got != "secret" {
			t.Errorf("代理没有带书源请求头 X-Token，实际 %q", got)
		}
		w.Header().Set("Content-Type", "audio/mpeg")
		_, _ = io.WriteString(w, "AUDIO")
	}))
	defer upstream.Close()

	svc := newAudioFixture(t.TempDir(), &port.AudioResource{
		URL:     upstream.URL + "/a.mp3",
		Headers: map[string]string{"X-Token": "secret"},
	})
	out, err := svc.ResolvePlayURL(context.Background(), 7, 2)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.URL, AudioRoutePrefix) || !strings.HasSuffix(out.URL, ".mp3") {
		t.Fatalf("播放地址应为 /stream/<sid>.mp3，实际 %q", out.URL)
	}
	if out.Index != 2 || out.Title != "第二章" {
		t.Fatalf("回执章节信息不对: %+v", out)
	}

	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, out.URL, nil))
	if rec.Code != http.StatusOK || rec.Body.String() != "AUDIO" {
		t.Fatalf("代理转发失败: %d %q", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("音频流不应被 WebView 缓存")
	}
}

func TestServeHTTPForwardsRangeAnd206(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Range"); got != "bytes=2-4" {
			t.Errorf("Range 未透传，实际 %q", got)
		}
		w.Header().Set("Content-Type", "audio/mpeg")
		w.Header().Set("Content-Range", "bytes 2-4/5")
		w.WriteHeader(http.StatusPartialContent)
		_, _ = io.WriteString(w, "DIO")
	}))
	defer upstream.Close()

	svc := newAudioFixture(t.TempDir(), &port.AudioResource{URL: upstream.URL + "/a.mp3"})
	out, err := svc.ResolvePlayURL(context.Background(), 7, 2)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, out.URL, nil)
	req.Header.Set("Range", "bytes=2-4")
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	if rec.Code != http.StatusPartialContent {
		t.Fatalf("应透传 206，实际 %d", rec.Code)
	}
	if got := rec.Header().Get("Content-Range"); got != "bytes 2-4/5" {
		t.Fatalf("Content-Range 丢失: %q", got)
	}
	if rec.Body.String() != "DIO" {
		t.Fatalf("分片内容不对: %q", rec.Body.String())
	}
}

func TestServeHTTPRejectsUnknownSession(t *testing.T) {
	svc := newAudioFixture(t.TempDir(), &port.AudioResource{URL: "https://example.com/a.mp3"})
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, AudioRoutePrefix+"deadbeef.mp3", nil))
	if rec.Code != http.StatusGone {
		t.Fatalf("过期会话应返回 410，实际 %d", rec.Code)
	}
	// 安卓宿主取元数据时也要拿到明确的失效状态，而不是把错误文本当 JSON 解析。
	rec = httptest.NewRecorder()
	svc.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, AudioMetaRoutePrefix+"deadbeef", nil))
	if rec.Code != http.StatusGone {
		t.Fatalf("元数据端点应返回 410，实际 %d", rec.Code)
	}
}

func TestServeMetaExposesURLAndHeaders(t *testing.T) {
	svc := newAudioFixture(t.TempDir(), &port.AudioResource{
		URL:     "https://cdn.example.com/a.mp3?sig=1",
		Headers: map[string]string{"Referer": "https://cdn.example.com/"},
	})
	out, err := svc.ResolvePlayURL(context.Background(), 7, 2)
	if err != nil {
		t.Fatal(err)
	}
	sid := audioSID(out.URL, AudioRoutePrefix)
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, AudioMetaRoutePrefix+sid, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("元数据端点应返回 200，实际 %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "https://cdn.example.com/a.mp3") || !strings.Contains(body, "Referer") {
		t.Fatalf("元数据缺少 URL 或请求头: %s", body)
	}
}

func TestAudioOfflineCachePreferred(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "cache", "audio", "7")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	cached := filepath.Join(dir, "2.mp3")
	if err := os.WriteFile(cached, []byte("offline"), 0o644); err != nil {
		t.Fatal(err)
	}
	// 故意给一个不可达的解析结果：命中离线缓存时不允许再联网。
	svc := newAudioFixture(root, &port.AudioResource{URL: "https://127.0.0.1:1/a.mp3"})
	out, err := svc.ResolvePlayURL(context.Background(), 7, 2)
	if err != nil {
		t.Fatal(err)
	}
	if sess := svc.lookupSession(audioSID(out.URL, AudioRoutePrefix)); sess == nil || sess.LocalPath != cached {
		t.Fatalf("应命中离线文件，实际会话 %+v", sess)
	}
	views, err := svc.CachedAudio(context.Background(), 7)
	if err != nil || len(views) != 1 || views[0].Index != 2 {
		t.Fatalf("缓存列表不对: %+v %v", views, err)
	}
	if err := svc.DeleteAudioCache(context.Background(), 7, []int{2}); err != nil {
		t.Fatal(err)
	}
	views, _ = svc.CachedAudio(context.Background(), 7)
	if len(views) != 0 {
		t.Fatalf("删除后应为空，实际 %+v", views)
	}
}

// 默认音频源「消消乐听书」的规则会读 source.getVariable()。听书解析必须和
// 搜索 / 详情一样先把源变量挂到书源实体上，否则解析出的地址会缺参数。
func TestResolvePlayURLAttachesSourceVariable(t *testing.T) {
	want := `{"token":"abc"}`
	svc := newAudioFixture(t.TempDir(),
		&port.AudioResource{URL: "https://cdn.example.com/a.mp3"},
		&audioVarRepo{v: want})
	if _, err := svc.ResolvePlayURL(context.Background(), 7, 2); err != nil {
		t.Fatal(err)
	}
	stub := svc.resolver.(*audioResolverStub)
	if stub.seenVariable != want {
		t.Fatalf("源变量没有传给解析器，实际 %q", stub.seenVariable)
	}
}

// sid 是 nonce：同一本书重新点播后旧会话立即失效，但别的书不受影响。
func TestAudioSessionIsNoncePerBook(t *testing.T) {
	svc := newAudioFixture(t.TempDir(), &port.AudioResource{URL: "https://cdn.example.com/a.mp3"})
	first, err := svc.ResolvePlayURL(context.Background(), 7, 2)
	if err != nil {
		t.Fatal(err)
	}
	other, err := svc.ResolvePlayURL(context.Background(), 8, 2)
	if err != nil {
		t.Fatal(err)
	}
	second, err := svc.ResolvePlayURL(context.Background(), 7, 2)
	if err != nil {
		t.Fatal(err)
	}
	if first.URL == second.URL {
		t.Fatal("重新点播必须生成新的 sid")
	}
	probe := func(audioURL string) int {
		rec := httptest.NewRecorder()
		svc.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, audioURL, nil))
		return rec.Code
	}
	if code := probe(AudioMetaRoutePrefix + audioSID(first.URL, AudioRoutePrefix)); code != http.StatusGone {
		t.Fatalf("同书旧会话应返回 410，实际 %d", code)
	}
	if code := probe(AudioMetaRoutePrefix + audioSID(other.URL, AudioRoutePrefix)); code != http.StatusOK {
		t.Fatalf("其他书的会话不应被清除，实际 %d", code)
	}
	if code := probe(AudioMetaRoutePrefix + audioSID(second.URL, AudioRoutePrefix)); code != http.StatusOK {
		t.Fatalf("新会话应可用，实际 %d", code)
	}
}

// 会话既有绝对上限也有闲置上限，过期后必须 410 而不是继续拿旧凭据代理。
func TestAudioSessionExpiry(t *testing.T) {
	svc := newAudioFixture(t.TempDir(), &port.AudioResource{URL: "https://cdn.example.com/a.mp3"})
	out, err := svc.ResolvePlayURL(context.Background(), 7, 2)
	if err != nil {
		t.Fatal(err)
	}
	sid := audioSID(out.URL, AudioRoutePrefix)
	metaURL := AudioMetaRoutePrefix + sid
	probe := func() int {
		rec := httptest.NewRecorder()
		svc.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, metaURL, nil))
		return rec.Code
	}
	if code := probe(); code != http.StatusOK {
		t.Fatalf("新会话应可用，实际 %d", code)
	}
	svc.sessions[sid].lastSeen = time.Now().Add(-audioSessionIdleTTL - time.Minute)
	if code := probe(); code != http.StatusGone {
		t.Fatalf("闲置过期应返回 410，实际 %d", code)
	}

	out, err = svc.ResolvePlayURL(context.Background(), 7, 2)
	if err != nil {
		t.Fatal(err)
	}
	sid2 := audioSID(out.URL, AudioRoutePrefix)
	svc.sessions[sid2].createdAt = time.Now().Add(-audioSessionMaxTTL - time.Minute)
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, AudioMetaRoutePrefix+sid2, nil))
	if rec.Code != http.StatusGone {
		t.Fatalf("超过绝对上限应返回 410，实际 %d", rec.Code)
	}
}

// 服务态由前端上报、Go 侧分配 seq 并广播；idle 不能残留上一本书的信息，
// 否则通知栏/其它窗口会一直挂着已经停掉的书。
func TestReportPlaybackStateBroadcastsSnapshot(t *testing.T) {
	svc := newAudioFixture(t.TempDir(), &port.AudioResource{URL: "https://cdn.example.com/a.mp3"})
	bus := &audioEventBus{}
	svc.events = bus

	in := dto.AudioPlaybackState{
		BookID: 7, BookName: "测试听书", ChapterIndex: 2, ChapterTitle: "第二章",
		Status: "playing", PositionMs: 12000, DurationMs: 300000,
		Rate: 1.2, PlayMode: "LIST_END_STOP", ClientID: "webview-A",
		Seq: 999, // 客户端伪造的序号必须被覆盖
	}
	out, err := svc.ReportPlaybackState(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	if out.Seq != 1 || out.Seq == in.Seq {
		t.Fatalf("seq 必须由服务端分配，实际 %d", out.Seq)
	}
	if bus.name != port.EventAudioPlaybackState {
		t.Fatalf("广播事件名不对：%q", bus.name)
	}
	got, ok := bus.payload.(dto.AudioPlaybackState)
	if !ok || got.BookID != 7 || got.ClientID != "webview-A" || got.PositionMs != 12000 {
		t.Fatalf("广播载荷不对：%+v", bus.payload)
	}
	if svc.PlaybackState().Seq != 1 {
		t.Fatal("快照没有落到服务态")
	}

	idle, err := svc.ReportPlaybackState(context.Background(), dto.AudioPlaybackState{
		Status: "idle", BookID: 7, ChapterIndex: 2, ClientID: "webview-A",
	})
	if err != nil {
		t.Fatal(err)
	}
	if idle.Seq != 2 || idle.BookID != 0 || idle.BookName != "" || idle.PositionMs != 0 {
		t.Fatalf("idle 快照应清空书籍信息，实际 %+v", idle)
	}
	if _, err := svc.ReportPlaybackState(context.Background(), dto.AudioPlaybackState{Status: "bogus"}); err == nil {
		t.Fatal("未知播放状态必须被拒绝")
	}
	if _, err := svc.ReportPlaybackState(context.Background(), dto.AudioPlaybackState{Status: "playing", PositionMs: -1}); err == nil {
		t.Fatal("负进度必须被拒绝")
	}
}

func TestAudioExt(t *testing.T) {
	cases := map[string]string{
		"https://cdn.example.com/a.mp3?sig=1": ".mp3",
		"https://cdn.example.com/a.m4a":       ".m4a",
		"https://cdn.example.com/stream":      ".mp3",
		"https://cdn.example.com/a.MP3":       ".mp3",
		"https://cdn.example.com/a.exe":       ".mp3",
	}
	for in, want := range cases {
		if got := audioExt(in); got != want {
			t.Errorf("audioExt(%q) = %q，期望 %q", in, got, want)
		}
	}
}
