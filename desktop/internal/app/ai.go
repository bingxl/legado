package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// errAIUnset 表示还没配置过 AI 服务。
//
// 这是全新安装的正常状态：读配置时当「空配置」处理，
// 而用户主动发起需要 AI 的操作时，要给一句看得懂的话。
var errAIUnset = fmt.Errorf("%w: 还没有配置 AI 服务，请先在「设置 → AI」里填写服务地址与模型", domain.ErrNotConfigured)

// AIDeps 聚合 AI 服务的依赖。
//
// 用聚合结构而非长参数列表：这个服务会依赖越来越多的仓储与端口，
// 逐个传参会让构造函数签名迅速失控（CacheService 已是前车之鉴）。
type AIDeps struct {
	Settings port.SettingsStore
	LLM      port.LLMClient
	Bus      port.EventBus

	Content   *ContentProvider
	Cache     port.ChapterCacheRepository
	Chunks    port.AIChunkRepository
	Summaries port.AISummaryRepository
	States    port.AIIndexStateRepository
	Chats     port.AIChatRepository
}

// AIService 提供 AI 总结与基于书籍内容的问答能力。
type AIService struct {
	settings port.SettingsStore
	llm      port.LLMClient
	bus      port.EventBus

	content   *ContentProvider
	cache     port.ChapterCacheRepository
	chunks    port.AIChunkRepository
	summaries port.AISummaryRepository
	states    port.AIIndexStateRepository
	chats     port.AIChatRepository

	// jobMu 保护索引任务表；同书只允许一个索引任务在跑。
	jobMu sync.Mutex
	jobs  map[int64]*aiIndexJob

	// answerMu 保护回答任务表；同会话只允许一个回答在生成。
	answerMu sync.Mutex
	answers  map[int64]*aiAnswerJob
}

// NewAIService 创建 AI 服务。
func NewAIService(d AIDeps) *AIService {
	return &AIService{
		settings:  d.Settings,
		llm:       d.LLM,
		bus:       d.Bus,
		content:   d.Content,
		cache:     d.Cache,
		chunks:    d.Chunks,
		summaries: d.Summaries,
		states:    d.States,
		chats:     d.Chats,
		jobs:      make(map[int64]*aiIndexJob),
		answers:   make(map[int64]*aiAnswerJob),
	}
}

// ── 配置 ───────────────────────────────────────────────────

// config 读取配置；未配置时返回 errAIUnset。
func (s *AIService) config(ctx context.Context) (*domain.AIConfig, error) {
	if s.settings == nil {
		return nil, fmt.Errorf("%w: 未配置持久化存储", domain.ErrNotConfigured)
	}
	raw, err := s.settings.Get(ctx, port.SettingAI)
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			return nil, errAIUnset
		}
		return nil, err
	}
	if strings.TrimSpace(raw) == "" {
		return nil, errAIUnset
	}
	var cfg domain.AIConfig
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return nil, fmt.Errorf("%w: AI 配置解析失败", domain.ErrNotConfigured)
	}
	return &cfg, nil
}

// persistConfig 序列化并写入配置。
func (s *AIService) persistConfig(ctx context.Context, cfg *domain.AIConfig) error {
	data, err := json.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("序列化 AI 配置失败: %w", err)
	}
	return s.settings.Set(ctx, port.SettingAI, string(data))
}

// GetConfig 读取配置视图（不含密钥）。
//
// 未配置时返回零值视图而不是错误：设置页首次打开必须能正常渲染空表单，
// 报错会让用户以为功能坏了。
func (s *AIService) GetConfig(ctx context.Context) (dto.AIConfigView, error) {
	cfg, err := s.config(ctx)
	if err != nil {
		if errors.Is(err, domain.ErrNotConfigured) {
			return dto.AIConfigView{}, nil
		}
		return dto.AIConfigView{}, err
	}
	return dto.NewAIConfigView(cfg), nil
}

// SaveConfig 保存配置。APIKey 传空串表示保持原密钥不变。
func (s *AIService) SaveConfig(ctx context.Context, in dto.AIConfigInput) (dto.AIConfigView, error) {
	base, err := s.config(ctx)
	if err != nil {
		if !errors.Is(err, domain.ErrNotConfigured) {
			return dto.AIConfigView{}, err
		}
		base = nil
	}

	if u := strings.TrimSpace(in.BaseURL); u != "" &&
		!strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
		return dto.AIConfigView{}, fmt.Errorf("%w: 服务地址需以 http:// 或 https:// 开头", domain.ErrInvalidArgument)
	}
	if u := strings.TrimSpace(in.EmbeddingBaseURL); u != "" &&
		!strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
		return dto.AIConfigView{}, fmt.Errorf("%w: 向量服务地址需以 http:// 或 https:// 开头", domain.ErrInvalidArgument)
	}

	cfg := dto.AIConfigPatch(base, in)
	if err := s.persistConfig(ctx, &cfg); err != nil {
		return dto.AIConfigView{}, err
	}
	return dto.NewAIConfigView(&cfg), nil
}

// TestConnection 用给定配置（未保存也可）探测连通性。
//
// 对话失败直接返回错误；向量失败只体现在结果里——没配或配错向量服务时，
// 检索会降级为关键词匹配，功能仍可用，不该阻断用户。
func (s *AIService) TestConnection(ctx context.Context, in dto.AIConfigInput) (dto.AITestResult, error) {
	base, err := s.config(ctx)
	if err != nil && !errors.Is(err, domain.ErrNotConfigured) {
		return dto.AITestResult{}, err
	}
	cfg := dto.AIConfigPatch(base, in)

	if !cfg.Configured() {
		return dto.AITestResult{}, fmt.Errorf("%w: 请先填写服务地址与模型", domain.ErrInvalidArgument)
	}

	reply, err := s.llm.Chat(ctx, cfg, port.ChatRequest{
		Messages: []port.ChatMessage{{Role: domain.AIRoleUser, Content: "ping"}},
		// 只要拿到 200 就证明地址、密钥、模型三者都对，内容不重要。
		MaxTokens: 16,
	})
	if err != nil {
		return dto.AITestResult{}, wrapAIRemoteError(err)
	}

	res := dto.AITestResult{ChatOK: true, ChatReply: strings.TrimSpace(reply.Content)}

	if !cfg.HasEmbedding() {
		res.EmbeddingMessage = "未配置向量模型，检索将使用关键词匹配"
		return res, nil
	}

	vecs, err := s.llm.Embed(ctx, cfg, cfg.EmbeddingModel, []string{"ping"})
	if err != nil {
		res.EmbeddingMessage = "向量服务不可用：" + err.Error()
		return res, nil
	}
	if len(vecs) == 0 || len(vecs[0]) == 0 {
		res.EmbeddingMessage = "向量服务返回了空向量"
		return res, nil
	}
	res.EmbeddingOK = true
	res.EmbeddingDim = len(vecs[0])
	return res, nil
}

// wrapAIRemoteError 把 AI 错误翻译成面向用户的领域错误。
func wrapAIRemoteError(err error) error {
	var aiErr *port.AIError
	if errors.As(err, &aiErr) {
		return fmt.Errorf("%w: %s", domain.ErrRemoteFailed, aiErr.Message)
	}
	if errors.Is(err, context.Canceled) {
		return err
	}
	return fmt.Errorf("%w: %v", domain.ErrRemoteFailed, err)
}

// aiIndexJob 是一次索引任务的运行时状态，用于取消与等待退出。
//
// 任务本身不落库：进度与已完成的部分由 ai_index_state 与 ai_chunks/ai_summaries
// 持久化，进程重启后靠这些表恢复；内存里的 job 只解决「本次运行怎么停下来」。
type aiIndexJob struct {
	bookID int64
	cancel context.CancelFunc
	// doneCh 在任务 goroutine 完全退出后关闭，供取消方等待，避免任务残留。
	doneCh chan struct{}

	// mu 保护 state：任务 goroutine 更新进度，查询与取消路径会读它。
	mu    sync.Mutex
	state domain.AIIndexState
}

// snapshot 返回状态的副本。
func (j *aiIndexJob) snapshot() domain.AIIndexState {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.state
}

// update 在锁内修改状态并返回副本。
func (j *aiIndexJob) update(fn func(*domain.AIIndexState)) domain.AIIndexState {
	j.mu.Lock()
	defer j.mu.Unlock()
	fn(&j.state)
	return j.state
}
