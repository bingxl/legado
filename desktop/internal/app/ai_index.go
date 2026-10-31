package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

const (
	// aiSummaryGroupTokens 是「一次摘要调用」的输入预算。
	// 按预算打包而不是按章节数：一本千章的书按章打包会产生上千次调用，
	// 按预算打包后同样一本书只需一两百次。
	aiSummaryGroupTokens = 6000
	// aiSummaryMaxTokens 限制单次摘要的输出长度，避免模型啰嗦。
	aiSummaryMaxTokens = 900
	// aiDefaultConcurrency 是摘要阶段的并发度。
	aiDefaultConcurrency = 3
	// aiEmbedBatch 是单次向量化请求的切片数。
	aiEmbedBatch = 32
	// aiFetchProgressStep 控制「取正文」阶段的进度上报间隔（章）。
	aiFetchProgressStep = 10
)

// chapterText 是一章的纯文本。
type chapterText struct {
	Index int
	Title string
	Text  string
}

// summaryInput 是一层摘要中某一条的输入。
type summaryInput struct {
	Level       int
	Ordinal     int
	Text        string
	ChapterFrom int
	ChapterTo   int
}

// ── 对外接口 ────────────────────────────────────────────────

// StartIndex 启动一本书的索引任务，立即返回当前状态。
//
// 为什么不在调用里同步跑完：整本索引可能几十分钟，绑定方法必须马上返回，
// 否则前端会一直转圈且无法取消。进度通过事件推送。
func (s *AIService) StartIndex(ctx context.Context, bookID int64, scope string, from, to int) (dto.AIIndexStatusView, error) {
	if bookID == 0 {
		return dto.AIIndexStatusView{}, fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	cfg, err := s.config(ctx)
	if err != nil {
		return dto.AIIndexStatusView{}, err
	}
	if !cfg.Configured() {
		return dto.AIIndexStatusView{}, errAIUnset
	}
	if s.content == nil || s.chunks == nil || s.summaries == nil || s.states == nil {
		return dto.AIIndexStatusView{}, fmt.Errorf("%w: AI 索引未就绪", domain.ErrNotConfigured)
	}

	book, chapters, err := s.content.BookAndChapters(ctx, bookID)
	if err != nil {
		return dto.AIIndexStatusView{}, err
	}
	from, to, err = resolveAIScope(book, chapters, scope, from, to)
	if err != nil {
		return dto.AIIndexStatusView{}, err
	}
	if scope == "" {
		scope = domain.AIScopeAll
	}

	s.jobMu.Lock()
	if _, running := s.jobs[bookID]; running {
		s.jobMu.Unlock()
		return dto.AIIndexStatusView{}, fmt.Errorf("%w: 这本书正在建立索引", domain.ErrAlreadyExists)
	}
	// 任务 ctx 必须与请求 ctx 脱钩：绑定方法返回后请求 ctx 就被取消了。
	jobCtx, cancel := context.WithCancel(context.Background())
	job := &aiIndexJob{
		bookID: bookID,
		cancel: cancel,
		doneCh: make(chan struct{}),
		state: domain.AIIndexState{
			BookID: bookID, Scope: scope, ChapterFrom: from, ChapterTo: to,
			Status: domain.AIIndexRunning,
		},
	}
	s.jobs[bookID] = job
	s.jobMu.Unlock()

	if err := s.states.Put(ctx, &job.state); err != nil {
		s.removeJob(bookID)
		cancel()
		close(job.doneCh)
		return dto.AIIndexStatusView{}, err
	}
	s.emitIndex(job, dto.AIPhaseFetch, 0, len(chapters), "准备索引")

	go s.runIndex(jobCtx, job, book, chapters, cfg)

	return s.statusView(ctx, bookID)
}

// CancelIndex 取消某本书正在进行的索引任务。
func (s *AIService) CancelIndex(ctx context.Context, bookID int64) error {
	s.jobMu.Lock()
	job, ok := s.jobs[bookID]
	s.jobMu.Unlock()
	if !ok {
		return nil
	}
	job.cancel()
	// 等任务真正退出，避免刚取消就重启导致两个任务同时写库。
	select {
	case <-job.doneCh:
	case <-time.After(5 * time.Second):
	}
	return nil
}

// IndexStatus 返回某本书的索引状态。
func (s *AIService) IndexStatus(ctx context.Context, bookID int64) (dto.AIIndexStatusView, error) {
	if bookID == 0 {
		return dto.AIIndexStatusView{}, fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	return s.statusView(ctx, bookID)
}

// DeleteIndex 删除某本书的全部索引数据（切片、摘要、状态）。
func (s *AIService) DeleteIndex(ctx context.Context, bookID int64) error {
	if bookID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	if err := s.CancelIndex(ctx, bookID); err != nil {
		return err
	}
	if s.chunks != nil {
		if err := s.chunks.DeleteByBook(ctx, bookID); err != nil {
			return err
		}
	}
	if s.summaries != nil {
		if err := s.summaries.DeleteByBook(ctx, bookID); err != nil {
			return err
		}
	}
	if s.states != nil {
		if err := s.states.Delete(ctx, bookID); err != nil {
			return err
		}
	}
	return nil
}

// GetSummary 返回某本书已生成的全书摘要。
func (s *AIService) GetSummary(ctx context.Context, bookID int64) (dto.AISummaryView, error) {
	if s.summaries == nil {
		return dto.AISummaryView{}, fmt.Errorf("%w: AI 索引未就绪", domain.ErrNotConfigured)
	}
	top, err := s.summaries.Top(ctx, bookID)
	if err != nil {
		if err == domain.ErrNotFound {
			return dto.AISummaryView{}, nil
		}
		return dto.AISummaryView{}, err
	}
	return dto.NewAISummaryView(top), nil
}

// SummarizeChapters 直接对指定章节区间生成摘要，不建立完整索引。
//
// 用途是「只想看看这几章讲了什么」：完整索引要切片、向量化、逐层归并，
// 只为一个区间不值得。这条路径不写 ai_chunks，也不产生全书摘要。
func (s *AIService) SummarizeChapters(ctx context.Context, bookID int64, from, to int) (string, error) {
	if bookID == 0 {
		return "", fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	cfg, err := s.config(ctx)
	if err != nil {
		return "", err
	}
	if !cfg.Configured() {
		return "", errAIUnset
	}
	if s.content == nil {
		return "", fmt.Errorf("%w: 正文服务未就绪", domain.ErrNotConfigured)
	}
	book, chapters, err := s.content.BookAndChapters(ctx, bookID)
	if err != nil {
		return "", err
	}
	from, to, err = resolveAIScope(book, chapters, domain.AIScopeRange, from, to)
	if err != nil {
		return "", err
	}

	job := &aiIndexJob{bookID: bookID}
	job.state.ChapterFrom, job.state.ChapterTo = from, to
	texts, err := s.loadChapterTexts(ctx, job, book, chapters)
	if err != nil {
		return "", err
	}
	if len(texts) == 0 {
		return "", fmt.Errorf("%w: 这段章节没有可读正文，建议先缓存", domain.ErrInvalidArgument)
	}

	var sb strings.Builder
	for _, t := range texts {
		sb.WriteString("【")
		sb.WriteString(t.Title)
		sb.WriteString("】\n")
		sb.WriteString(t.Text)
		sb.WriteString("\n")
	}
	return s.summarizeText(ctx, cfg, 1, sb.String())
}

// ── 索引流程 ────────────────────────────────────────────────

func (s *AIService) runIndex(ctx context.Context, job *aiIndexJob, book *domain.Book,
	chapters []*domain.BookChapter, cfg *domain.AIConfig) {

	defer s.removeJob(job.bookID)
	defer close(job.doneCh)

	fail := func(err error) {
		status := domain.AIIndexFailed
		if ctx.Err() != nil {
			status = domain.AIIndexCanceled
			err = nil
		}
		st := job.update(func(st *domain.AIIndexState) {
			st.Status = status
			if err != nil {
				st.Error = err.Error()
			}
		})
		s.states.Put(context.Background(), &st)
		phase := dto.AIPhaseFailed
		msg := ""
		if status == domain.AIIndexCanceled {
			phase = dto.AIPhaseCanceled
		} else if err != nil {
			msg = err.Error()
		}
		s.emitIndex(job, phase, 0, 0, msg)
	}

	texts, err := s.loadChapterTexts(ctx, job, book, chapters)
	if err != nil {
		fail(err)
		return
	}
	if len(texts) == 0 {
		fail(fmt.Errorf("%w: 没有可索引的正文。网络书建议先「缓存」整本再建索引", domain.ErrInvalidArgument))
		return
	}
	s.emitIndex(job, dto.AIPhaseChunk, 0, len(texts), "切分正文")

	chunks, err := s.buildChunks(ctx, job, texts)
	if err != nil {
		fail(err)
		return
	}

	if err := s.embedChunks(ctx, job, cfg, chunks); err != nil {
		fail(err)
		return
	}
	if ctx.Err() != nil {
		fail(ctx.Err())
		return
	}

	if err := s.buildSummaryChain(ctx, job, cfg, chunks); err != nil {
		fail(err)
		return
	}

	st := job.update(func(st *domain.AIIndexState) {
		st.Status = domain.AIIndexDone
		st.ChunkCount = len(chunks)
	})
	if err := s.states.Put(context.Background(), &st); err != nil {
		fail(err)
		return
	}
	s.emitIndex(job, dto.AIPhaseDone, len(chunks), len(chunks), "索引完成")
}

// loadChapterTexts 取回目标章节的纯文本。
func (s *AIService) loadChapterTexts(ctx context.Context, job *aiIndexJob,
	book *domain.Book, chapters []*domain.BookChapter) ([]chapterText, error) {

	targets := filterAIChapters(chapters, job.state.ChapterFrom, job.state.ChapterTo)
	if len(targets) == 0 {
		return nil, nil
	}

	// 已缓存的正文一次读全：逐章 Get 会产生上千次查询。
	cached := map[int]string{}
	if s.cache != nil && !book.IsLocal() {
		if list, err := s.cache.ListWithContent(ctx, book.ID); err == nil {
			for _, c := range list {
				if c.HTML != "" {
					cached[c.Index] = c.HTML
				}
			}
		}
	}

	out := make([]chapterText, 0, len(targets))
	skipped := 0
	for i, ch := range targets {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var text string
		if html, ok := cached[ch.Index]; ok {
			text = aiPlainText(html)
		} else {
			got, err := s.content.Chapter(ctx, book.ID, ch.Index)
			if err != nil {
				// 单章抓不到是常态（源站偶发失败），不该让整本书索引失败。
				skipped++
				continue
			}
			text = aiPlainText(got.HTML)
		}
		if strings.TrimSpace(text) == "" {
			skipped++
			continue
		}
		out = append(out, chapterText{Index: ch.Index, Title: ch.Title, Text: text})

		if i%aiFetchProgressStep == 0 {
			s.emitIndex(job, dto.AIPhaseFetch, i+1, len(targets),
				fmt.Sprintf("正在读取第 %d/%d 章", i+1, len(targets)))
		}
	}
	if skipped > 0 {
		job.update(func(st *domain.AIIndexState) {
			st.Error = fmt.Sprintf("有 %d 章没有取到正文，已跳过", skipped)
		})
	}
	return out, nil
}

// buildChunks 切片并入库。
func (s *AIService) buildChunks(ctx context.Context, job *aiIndexJob, texts []chapterText) ([]*domain.AIChunk, error) {
	var chunks []*domain.AIChunk
	ordinal := 0
	for _, t := range texts {
		parts := splitChapterText(t.Title, t.Text, t.Index, ordinal)
		for _, p := range parts {
			chunks = append(chunks, &domain.AIChunk{
				BookID:     job.bookID,
				ChapterIdx: p.ChapterIdx,
				Ordinal:    p.Ordinal,
				CharStart:  p.CharStart,
				CharEnd:    p.CharEnd,
				Title:      p.Title,
				Text:       p.Text,
				TokenCount: p.TokenCount,
				SrcHash:    textHash(p.Text),
			})
		}
		ordinal += len(parts)
	}
	if len(chunks) == 0 {
		return nil, fmt.Errorf("%w: 正文为空，无法切片", domain.ErrInvalidArgument)
	}
	if err := s.chunks.PutBulk(ctx, chunks); err != nil {
		return nil, err
	}
	// 正文变短时清掉尾部多余切片，否则会召回「已不存在的章节」。
	if err := s.chunks.DeleteBeyond(ctx, job.bookID, len(chunks)-1); err != nil {
		return nil, err
	}

	// 入库后要拿回带 ID 的版本，向量更新依赖 ID。
	stored, err := s.chunks.List(ctx, job.bookID)
	if err != nil {
		return nil, err
	}
	job.update(func(st *domain.AIIndexState) {
		st.ChunkCount = len(stored)
	})
	s.emitIndex(job, dto.AIPhaseChunk, len(stored), len(stored), "切片完成")
	return stored, nil
}

// embedChunks 为尚未向量化的切片补上向量。
//
// 向量化失败不中断索引：没有向量时问答会退回关键词召回，功能仍在。
// 但失败原因要写进状态，否则用户会以为「明明配了 embedding 却不生效」。
func (s *AIService) embedChunks(ctx context.Context, job *aiIndexJob,
	cfg *domain.AIConfig, chunks []*domain.AIChunk) error {

	if !cfg.HasEmbedding() {
		return nil
	}
	var pending []*domain.AIChunk
	for _, c := range chunks {
		if !c.HasVector() {
			pending = append(pending, c)
		}
	}
	if len(pending) == 0 {
		return nil
	}

	total := len(pending)
	for start := 0; start < len(pending); start += aiEmbedBatch {
		if err := ctx.Err(); err != nil {
			return err
		}
		end := start + aiEmbedBatch
		if end > len(pending) {
			end = len(pending)
		}
		batch := pending[start:end]

		inputs := make([]string, len(batch))
		for i, c := range batch {
			inputs[i] = c.Text
		}
		vecs, err := s.llm.Embed(ctx, *cfg, cfg.EmbeddingModel, inputs)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			job.update(func(st *domain.AIIndexState) {
				st.Error = "向量化失败，问答将使用关键词匹配：" + err.Error()
			})
			return nil
		}
		for i, c := range batch {
			if i >= len(vecs) || len(vecs[i]) == 0 {
				continue
			}
			dim := len(vecs[i])
			if err := s.chunks.UpdateEmbedding(ctx, c.ID, vecs[i], cfg.EmbeddingModel, dim); err != nil {
				return err
			}
			c.Embedding = vecs[i]
			c.EmbModel = cfg.EmbeddingModel
			c.EmbDim = dim
		}
		done := end
		st := job.update(func(st *domain.AIIndexState) { st.EmbDone = done })
		s.emitIndex(job, dto.AIPhaseEmbed, done, total,
			fmt.Sprintf("向量化 %d/%d", st.EmbDone, total))
	}
	return nil
}

// buildSummaryChain 递归归并出分层摘要，直到只剩一条（全书摘要）。
func (s *AIService) buildSummaryChain(ctx context.Context, job *aiIndexJob,
	cfg *domain.AIConfig, chunks []*domain.AIChunk) error {

	if len(chunks) == 0 {
		return nil
	}

	groups := groupByTokenBudget(len(chunks),
		func(i int) int { return chunks[i].TokenCount }, aiSummaryGroupTokens)

	inputs := make([]summaryInput, len(groups))
	for i, g := range groups {
		inputs[i] = summaryInput{
			Level:       1,
			Ordinal:     i,
			Text:        joinChunkTexts(chunks, g),
			ChapterFrom: chunks[g[0]].ChapterIdx,
			ChapterTo:   chunks[g[len(g)-1]].ChapterIdx,
		}
	}

	job.update(func(st *domain.AIIndexState) {
		st.SummaryTotal = len(inputs)
		st.SummaryDone = 0
	})

	level := 1
	for {
		sums, err := s.summarizeLevel(ctx, job, cfg, level, inputs)
		if err != nil {
			return err
		}
		if len(sums) <= 1 {
			// 比最终层级更高的旧摘要已失效（下层变了），清掉以免被当成本书摘要。
			if s.summaries != nil {
				if err := s.summaries.DeleteFromLevel(ctx, job.bookID, level+1); err != nil {
					return err
				}
			}
			return nil
		}

		level++
		nextGroups := groupByTokenBudget(len(sums),
			func(i int) int { return sums[i].TokenCount }, aiSummaryGroupTokens)
		// 总条数是**累积**的：每上升一层都有新的工作量，若重置为下一层的条数，
		// 进度条会倒退，而若只增分母不增分子则会出现「23/22」这种荒谬比值。
		job.update(func(st *domain.AIIndexState) {
			st.SummaryTotal += len(nextGroups)
		})
		next := make([]summaryInput, len(nextGroups))
		for i, g := range nextGroups {
			next[i] = summaryInput{
				Level:       level,
				Ordinal:     i,
				Text:        joinSummaryTexts(sums, g),
				ChapterFrom: sums[g[0]].ChapterFrom,
				ChapterTo:   sums[g[len(g)-1]].ChapterTo,
			}
		}
		inputs = next
	}
}

// summarizeLevel 并发生成某一层的全部摘要。
func (s *AIService) summarizeLevel(ctx context.Context, job *aiIndexJob,
	cfg *domain.AIConfig, level int, inputs []summaryInput) ([]*domain.AISummary, error) {

	// 一次取出该层已有摘要，供断点续跑复用；避免每条都查一次库。
	existing := map[int]*domain.AISummary{}
	if s.summaries != nil {
		if olds, err := s.summaries.Level(ctx, job.bookID, level); err == nil {
			for _, o := range olds {
				existing[o.Ordinal] = o
			}
		}
	}

	concurrency := cfg.MaxConcurrent
	if concurrency <= 0 {
		concurrency = aiDefaultConcurrency
	}
	if concurrency > len(inputs) {
		concurrency = len(inputs)
	}

	results := make([]*domain.AISummary, len(inputs))
	sem := make(chan struct{}, concurrency)
	errCh := make(chan error, len(inputs))
	var wg sync.WaitGroup

	for i := range inputs {
		if ctx.Err() != nil {
			break
		}
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				return
			}
			defer func() { <-sem }()

			in := inputs[i]
			hash := textHash(in.Text)

			// 断点续跑：输入没变且上次成功，直接复用，不重复花钱。
			if old, ok := existing[in.Ordinal]; ok && old.OK && old.SrcHash == hash {
				results[i] = old
				s.bumpSummary(job)
				return
			}

			content, err := s.summarizeText(ctx, cfg, in.Level, in.Text)
			if err != nil {
				select {
				case errCh <- err:
				default:
				}
				return
			}

			sum := &domain.AISummary{
				BookID:      job.bookID,
				Level:       in.Level,
				Ordinal:     in.Ordinal,
				ParentLevel: in.Level - 1,
				ParentOrd:   in.Ordinal,
				ChapterFrom: in.ChapterFrom,
				ChapterTo:   in.ChapterTo,
				Content:     content,
				TokenCount:  estimateTokens(content),
				Model:       cfg.Model,
				SrcHash:     hash,
				OK:          true,
			}
			if err := s.summaries.Put(ctx, sum); err != nil {
				select {
				case errCh <- err:
				default:
				}
				return
			}
			results[i] = sum
			s.bumpSummary(job)
		}(i)
	}
	wg.Wait()

	if err := ctx.Err(); err != nil {
		return nil, err
	}
	select {
	case err := <-errCh:
		return nil, err
	default:
	}

	out := make([]*domain.AISummary, 0, len(results))
	for _, r := range results {
		if r != nil {
			out = append(out, r)
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%w: 摘要生成全部失败", domain.ErrRemoteFailed)
	}
	return out, nil
}

// summarizeText 调一次模型生成摘要。
func (s *AIService) summarizeText(ctx context.Context, cfg *domain.AIConfig, level int, text string) (string, error) {
	resp, err := s.llm.Chat(ctx, *cfg, port.ChatRequest{
		Messages: []port.ChatMessage{
			{Role: domain.AIRoleSystem, Content: aiSummarySystemPrompt(level)},
			{Role: domain.AIRoleUser, Content: text},
		},
		MaxTokens: aiSummaryMaxTokens,
	})
	if err != nil {
		return "", err
	}
	out := strings.TrimSpace(resp.Content)
	if out == "" {
		return "", fmt.Errorf("%w: 模型返回了空摘要", domain.ErrRemoteFailed)
	}
	return out, nil
}

// aiSummarySystemPrompt 给出摘要指令。
//
// 明确禁止「本文讲述了」这类套话，是因为这类开头会在逐层归并中不断累积，
// 越到高层越空洞，最后全书摘要变成一句废话。
func aiSummarySystemPrompt(level int) string {
	const base = "你在为一本书做阅读笔记，供读者回顾内容与后续提问。"
	if level <= 1 {
		return base + "请用 200~300 字概括下面这段正文的关键情节、人物与因果关系，" +
			"保留专有名词、数字与重要转折。不要评价文笔，不要写「本段讲述了」这类套话，直接给内容。"
	}
	return base + "下面是同一本书若干段落的摘要。请合并成一段 300~400 字的整体概述，" +
		"保留主线脉络、关键人物关系与重要转折，删掉重复表述。不要分点，不要加标题，不要写导语。"
}

// ── 内部工具 ────────────────────────────────────────────────

func (s *AIService) removeJob(bookID int64) {
	s.jobMu.Lock()
	delete(s.jobs, bookID)
	s.jobMu.Unlock()
}

// emitIndex 推送索引进度。用 Background ctx：任务被取消时进度仍要发出去。
// aiEventSeq 给索引进度事件编号，进程内单调递增。
//
// 事件由前端运行时异步投递，到达顺序不保证与产生顺序一致；没有序号时，
// 终态（done）之后再到达一个早阶段的 embed/summary 事件，界面就会从
// 「索引已就绪」翻回「索引进行中」——按钮也跟着从「删除索引」变成「取消索引」。
var aiEventSeq atomic.Int64

func (s *AIService) emitIndex(job *aiIndexJob, phase string, done, total int, msg string) {
	if s.bus == nil {
		return
	}
	_ = s.bus.Emit(context.Background(), port.EventAIIndexProgress, dto.AIIndexProgress{
		BookID: job.bookID, Phase: phase, Done: done, Total: total, Message: msg,
		Seq: aiEventSeq.Add(1),
	})
}

func (s *AIService) bumpSummary(job *aiIndexJob) {
	st := job.update(func(st *domain.AIIndexState) { st.SummaryDone++ })
	s.emitIndex(job, dto.AIPhaseSummary, st.SummaryDone, st.SummaryTotal,
		fmt.Sprintf("生成摘要 %d/%d", st.SummaryDone, st.SummaryTotal))
}

func (s *AIService) statusView(ctx context.Context, bookID int64) (dto.AIIndexStatusView, error) {
	view := dto.AIIndexStatusView{BookID: bookID}

	if s.states != nil {
		st, err := s.states.Get(ctx, bookID)
		if err != nil && err != domain.ErrNotFound {
			return view, err
		}
		if st != nil {
			t := st.UpdatedAt
			view.Scope = st.Scope
			view.ChapterFrom = st.ChapterFrom
			view.ChapterTo = st.ChapterTo
			view.Status = st.Status
			view.ChunkCount = st.ChunkCount
			view.SummaryDone = st.SummaryDone
			view.SummaryTotal = st.SummaryTotal
			view.Error = st.Error
			if !t.IsZero() {
				view.UpdatedAt = &t
			}
		}
	}
	if view.Status == "" {
		view.Status = domain.AIIndexIdle
	}
	// 正在跑的任务以内存状态为准：库里的计数是阶段性的，可能落后。
	s.jobMu.Lock()
	if job, ok := s.jobs[bookID]; ok {
		snap := job.snapshot()
		view.Status = snap.Status
		view.ChunkCount = snap.ChunkCount
		view.SummaryDone = snap.SummaryDone
		view.SummaryTotal = snap.SummaryTotal
	}
	s.jobMu.Unlock()

	if s.chunks != nil {
		if n, err := s.chunks.Count(ctx, bookID); err == nil && n > 0 {
			view.ChunkCount = n
		}
		if n, err := s.chunks.CountWithVector(ctx, bookID); err == nil {
			view.VectorCount = n
		}
	}
	if s.summaries != nil {
		if top, err := s.summaries.Top(ctx, bookID); err == nil && top != nil && top.OK {
			view.HasSummary = true
			view.Summary = top.Content
		}
	}
	return view, nil
}

// resolveAIScope 把用户选择的范围换算成章节序号区间。
func resolveAIScope(book *domain.Book, chapters []*domain.BookChapter,
	scope string, from, to int) (int, int, error) {

	if len(chapters) == 0 {
		return 0, 0, fmt.Errorf("%w: 这本书还没有目录", domain.ErrInvalidArgument)
	}
	first := chapters[0].Index
	last := chapters[len(chapters)-1].Index

	switch scope {
	case "", domain.AIScopeAll:
		return first, last, nil
	case domain.AIScopeRead:
		// 「已读」= 目录开头读到当前进度。没开始读时退化成第一章，
		// 而不是报错——此时用户点「总结已读」多半是想看开头。
		idx := book.DurChapterIndex
		if idx < first {
			idx = first
		}
		if idx > last {
			idx = last
		}
		return first, idx, nil
	case domain.AIScopeRange:
		if from > to {
			return 0, 0, fmt.Errorf("%w: 起始章节不能大于结束章节", domain.ErrInvalidArgument)
		}
		if from < first || to > last {
			return 0, 0, fmt.Errorf("%w: 章节范围超出目录（%d~%d）", domain.ErrInvalidArgument, first, last)
		}
		return from, to, nil
	}
	return 0, 0, fmt.Errorf("%w: 未知的索引范围 %q", domain.ErrInvalidArgument, scope)
}

// filterAIChapters 取出范围内、非分卷的章节。
func filterAIChapters(chapters []*domain.BookChapter, from, to int) []*domain.BookChapter {
	out := make([]*domain.BookChapter, 0, len(chapters))
	for _, ch := range chapters {
		if ch.IsVolume {
			continue
		}
		if ch.Index < from || ch.Index > to {
			continue
		}
		out = append(out, ch)
	}
	return out
}

// groupByTokenBudget 按 token 预算把 0..n-1 分成若干组。
//
// 每条至少进一组（即使单独就超预算），否则会丢内容且无法前进。
func groupByTokenBudget(n int, tokenAt func(int) int, budget int) [][]int {
	if n <= 0 {
		return nil
	}
	if budget <= 0 {
		budget = aiSummaryGroupTokens
	}
	var out [][]int
	cur := make([]int, 0, 8)
	acc := 0
	for i := 0; i < n; i++ {
		t := tokenAt(i)
		if len(cur) > 0 && acc+t > budget {
			out = append(out, cur)
			cur = make([]int, 0, 8)
			acc = 0
		}
		cur = append(cur, i)
		acc += t
	}
	if len(cur) > 0 {
		out = append(out, cur)
	}
	return out
}

func joinChunkTexts(chunks []*domain.AIChunk, indexes []int) string {
	var sb strings.Builder
	for _, i := range indexes {
		if i < 0 || i >= len(chunks) {
			continue
		}
		sb.WriteString(chunks[i].Text)
		sb.WriteString("\n")
	}
	return sb.String()
}

func joinSummaryTexts(sums []*domain.AISummary, indexes []int) string {
	var sb strings.Builder
	for _, i := range indexes {
		if i < 0 || i >= len(sums) {
			continue
		}
		sb.WriteString(sums[i].Content)
		sb.WriteString("\n")
	}
	return sb.String()
}

// textHash 取前 8 字节的十六进制，用于判断输入是否变化。
//
// 不需要密码学强度：只用来跳过重复计算，碰撞概率低到可以忽略。
func textHash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:8])
}
