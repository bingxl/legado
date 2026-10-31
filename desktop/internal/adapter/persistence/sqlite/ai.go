package sqlite

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ── 向量编解码 ──────────────────────────────────────────────
//
// sqlite 没有向量类型，也没有可用的向量扩展（modernc 是纯 Go，加载不了
// sqlite-vec），所以把 float32 序列成 BLOB 存，检索时全读进内存算余弦。
// 用固定小端序而非 unsafe 强转：跨平台与跨架构稳定，代价只是几行循环。

func encodeVector(v []float32) []byte {
	if len(v) == 0 {
		return nil
	}
	buf := make([]byte, len(v)*4)
	for i, f := range v {
		binary.LittleEndian.PutUint32(buf[i*4:], math.Float32bits(f))
	}
	return buf
}

func decodeVector(buf []byte) []float32 {
	if len(buf) < 4 {
		return nil
	}
	n := len(buf) / 4
	v := make([]float32, n)
	for i := 0; i < n; i++ {
		v[i] = math.Float32frombits(binary.LittleEndian.Uint32(buf[i*4:]))
	}
	return v
}

// ── 切片仓储 ────────────────────────────────────────────────

// AIChunkRepo 实现 port.AIChunkRepository。
type AIChunkRepo struct {
	db *DB
}

// NewAIChunkRepo 创建 AI 切片仓储。
func NewAIChunkRepo(db *DB) *AIChunkRepo { return &AIChunkRepo{db: db} }

var _ port.AIChunkRepository = (*AIChunkRepo)(nil)

const aiChunkColumns = `id, book_id, chapter_idx, ordinal, char_start, char_end,
	title, text, token_count, src_hash, embedding, emb_model, emb_dim, created_at`

// PutBulk 批量写入切片。
//
// 走事务：一本书动辄上千片，逐条提交会让 sqlite 按条 fsync，慢一个数量级。
// 冲突时覆盖文本与偏移，但**保留已有向量**——只要 src_hash 没变就还能用，
// 上层据此跳过重复的向量化调用（那是唯一需要花钱的步骤）。
func (r *AIChunkRepo) PutBulk(ctx context.Context, chunks []*domain.AIChunk) error {
	if len(chunks) == 0 {
		return nil
	}
	now := time.Now().Unix()

	return r.db.Do(ctx, func(ctx context.Context) error {
		const query = `INSERT INTO ai_chunks
			(book_id, chapter_idx, ordinal, char_start, char_end, title, text,
			 token_count, src_hash, embedding, emb_model, emb_dim, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(book_id, ordinal) DO UPDATE SET
				chapter_idx=excluded.chapter_idx,
				char_start=excluded.char_start,
				char_end=excluded.char_end,
				title=excluded.title,
				text=excluded.text,
				token_count=excluded.token_count,
				embedding=CASE
					WHEN ai_chunks.src_hash = excluded.src_hash THEN ai_chunks.embedding
					ELSE NULL END,
				emb_model=CASE
					WHEN ai_chunks.src_hash = excluded.src_hash THEN ai_chunks.emb_model
					ELSE '' END,
				emb_dim=CASE
					WHEN ai_chunks.src_hash = excluded.src_hash THEN ai_chunks.emb_dim
					ELSE 0 END,
				src_hash=excluded.src_hash`

		for _, c := range chunks {
			if c.BookID == 0 {
				return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
			}
			created := c.CreatedAt
			if created.IsZero() {
				created = time.Unix(now, 0)
			}
			if _, err := r.db.q(ctx).ExecContext(ctx, query,
				c.BookID, c.ChapterIdx, c.Ordinal, c.CharStart, c.CharEnd, c.Title,
				c.Text, c.TokenCount, c.SrcHash, encodeVector(c.Embedding),
				c.EmbModel, c.EmbDim, created.Unix()); err != nil {
				return fmt.Errorf("写入 AI 切片失败: %w", err)
			}
		}
		return nil
	})
}

// UpdateEmbedding 只更新向量字段。
func (r *AIChunkRepo) UpdateEmbedding(ctx context.Context, id int64, vec []float32, model string, dim int) error {
	const query = `UPDATE ai_chunks SET embedding = ?, emb_model = ?, emb_dim = ? WHERE id = ?`
	res, err := r.db.q(ctx).ExecContext(ctx, query, encodeVector(vec), model, dim, id)
	if err != nil {
		return fmt.Errorf("写入 AI 向量失败: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return domain.ErrNotFound
	}
	return nil
}

// List 返回某本书的全部切片（含向量），按序号升序。
func (r *AIChunkRepo) List(ctx context.Context, bookID int64) ([]*domain.AIChunk, error) {
	return r.listWhere(ctx, `SELECT `+aiChunkColumns+`
		FROM ai_chunks WHERE book_id = ? ORDER BY ordinal ASC`, bookID)
}

// ListRange 返回指定序号区间的切片。
func (r *AIChunkRepo) ListRange(ctx context.Context, bookID int64, from, to int) ([]*domain.AIChunk, error) {
	return r.listWhere(ctx, `SELECT `+aiChunkColumns+`
		FROM ai_chunks WHERE book_id = ? AND ordinal >= ? AND ordinal <= ?
		ORDER BY ordinal ASC`, bookID, from, to)
}

func (r *AIChunkRepo) listWhere(ctx context.Context, query string, args ...any) ([]*domain.AIChunk, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("查询 AI 切片失败: %w", err)
	}
	defer rows.Close()

	var out []*domain.AIChunk
	for rows.Next() {
		c, err := scanAIChunk(rows)
		if err != nil {
			return nil, fmt.Errorf("读取 AI 切片失败: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Get 按主键取单条。
func (r *AIChunkRepo) Get(ctx context.Context, id int64) (*domain.AIChunk, error) {
	row := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT `+aiChunkColumns+` FROM ai_chunks WHERE id = ?`, id)
	c, err := scanAIChunk(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return c, nil
}

// Count 返回切片总数。
func (r *AIChunkRepo) Count(ctx context.Context, bookID int64) (int, error) {
	var n int
	err := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT COUNT(*) FROM ai_chunks WHERE book_id = ?`, bookID).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("统计 AI 切片失败: %w", err)
	}
	return n, nil
}

// CountWithVector 返回已具备向量的切片数。
func (r *AIChunkRepo) CountWithVector(ctx context.Context, bookID int64) (int, error) {
	var n int
	err := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT COUNT(*) FROM ai_chunks WHERE book_id = ? AND embedding IS NOT NULL`,
		bookID).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("统计 AI 向量失败: %w", err)
	}
	return n, nil
}

// DeleteBeyond 删除序号超过 maxOrdinal 的切片。
func (r *AIChunkRepo) DeleteBeyond(ctx context.Context, bookID int64, maxOrdinal int) error {
	_, err := r.db.q(ctx).ExecContext(ctx,
		`DELETE FROM ai_chunks WHERE book_id = ? AND ordinal > ?`, bookID, maxOrdinal)
	if err != nil {
		return fmt.Errorf("清理多余 AI 切片失败: %w", err)
	}
	return nil
}

// DeleteByBook 删除某本书的全部切片。
func (r *AIChunkRepo) DeleteByBook(ctx context.Context, bookID int64) error {
	_, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM ai_chunks WHERE book_id = ?`, bookID)
	if err != nil {
		return fmt.Errorf("删除 AI 切片失败: %w", err)
	}
	return nil
}

// DeleteByChapters 删除指定章节区间的切片（正文变更时局部重建）。
func (r *AIChunkRepo) DeleteByChapters(ctx context.Context, bookID int64, from, to int) error {
	_, err := r.db.q(ctx).ExecContext(ctx,
		`DELETE FROM ai_chunks WHERE book_id = ? AND chapter_idx >= ? AND chapter_idx <= ?`,
		bookID, from, to)
	if err != nil {
		return fmt.Errorf("删除 AI 切片失败: %w", err)
	}
	return nil
}

func scanAIChunk(s scanner) (*domain.AIChunk, error) {
	var (
		c       domain.AIChunk
		emb     []byte
		created int64
	)
	if err := s.Scan(&c.ID, &c.BookID, &c.ChapterIdx, &c.Ordinal, &c.CharStart, &c.CharEnd,
		&c.Title, &c.Text, &c.TokenCount, &c.SrcHash, &emb, &c.EmbModel, &c.EmbDim,
		&created); err != nil {
		return nil, err
	}
	c.Embedding = decodeVector(emb)
	c.CreatedAt = time.Unix(created, 0)
	return &c, nil
}

// ── 摘要仓储 ────────────────────────────────────────────────

// AISummaryRepo 实现 port.AISummaryRepository。
type AISummaryRepo struct {
	db *DB
}

// NewAISummaryRepo 创建 AI 摘要仓储。
func NewAISummaryRepo(db *DB) *AISummaryRepo { return &AISummaryRepo{db: db} }

var _ port.AISummaryRepository = (*AISummaryRepo)(nil)

const aiSummaryColumns = `id, book_id, level, ordinal, parent_level, parent_ord,
	chapter_from, chapter_to, content, token_count, model, src_hash, ok, error,
	created_at, updated_at`

// Put 写入或覆盖一条摘要。
func (r *AISummaryRepo) Put(ctx context.Context, s *domain.AISummary) error {
	if s.BookID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	now := time.Now()
	created := s.CreatedAt
	if created.IsZero() {
		created = now
	}
	const query = `INSERT INTO ai_summaries
		(book_id, level, ordinal, parent_level, parent_ord, chapter_from, chapter_to,
		 content, token_count, model, src_hash, ok, error, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(book_id, level, ordinal) DO UPDATE SET
			parent_level=excluded.parent_level,
			parent_ord=excluded.parent_ord,
			chapter_from=excluded.chapter_from,
			chapter_to=excluded.chapter_to,
			content=excluded.content,
			token_count=excluded.token_count,
			model=excluded.model,
			src_hash=excluded.src_hash,
			ok=excluded.ok,
			error=excluded.error,
			updated_at=excluded.updated_at`
	_, err := r.db.q(ctx).ExecContext(ctx, query,
		s.BookID, s.Level, s.Ordinal, s.ParentLevel, s.ParentOrd, s.ChapterFrom,
		s.ChapterTo, s.Content, s.TokenCount, s.Model, s.SrcHash, boolInt(s.OK),
		s.Error, created.Unix(), now.Unix())
	if err != nil {
		return fmt.Errorf("写入 AI 摘要失败: %w", err)
	}
	return nil
}

// Level 返回指定层级的全部摘要。
func (r *AISummaryRepo) Level(ctx context.Context, bookID int64, level int) ([]*domain.AISummary, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx,
		`SELECT `+aiSummaryColumns+` FROM ai_summaries
		 WHERE book_id = ? AND level = ? ORDER BY ordinal ASC`, bookID, level)
	if err != nil {
		return nil, fmt.Errorf("查询 AI 摘要失败: %w", err)
	}
	defer rows.Close()

	var out []*domain.AISummary
	for rows.Next() {
		s, err := scanAISummary(rows)
		if err != nil {
			return nil, fmt.Errorf("读取 AI 摘要失败: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// Top 返回最高层级的摘要（通常一条，即全书摘要）。
func (r *AISummaryRepo) Top(ctx context.Context, bookID int64) (*domain.AISummary, error) {
	row := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT `+aiSummaryColumns+` FROM ai_summaries
		 WHERE book_id = ? ORDER BY level DESC, ordinal ASC LIMIT 1`, bookID)
	s, err := scanAISummary(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return s, nil
}

// MaxLevel 返回已有摘要的最大层级；无摘要返回 0。
func (r *AISummaryRepo) MaxLevel(ctx context.Context, bookID int64) (int, error) {
	var lv int
	err := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT COALESCE(MAX(level), 0) FROM ai_summaries WHERE book_id = ?`, bookID).Scan(&lv)
	if err != nil {
		return 0, fmt.Errorf("统计 AI 摘要层级失败: %w", err)
	}
	return lv, nil
}

// DeleteByBook 删除某本书的全部摘要。
func (r *AISummaryRepo) DeleteByBook(ctx context.Context, bookID int64) error {
	_, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM ai_summaries WHERE book_id = ?`, bookID)
	if err != nil {
		return fmt.Errorf("删除 AI 摘要失败: %w", err)
	}
	return nil
}

// DeleteFromLevel 删除指定层级及以上的摘要。
//
// 下层内容一变，上层结论就不再成立，必须连带作废，否则会拿旧摘要回答新问题。
func (r *AISummaryRepo) DeleteFromLevel(ctx context.Context, bookID int64, level int) error {
	_, err := r.db.q(ctx).ExecContext(ctx,
		`DELETE FROM ai_summaries WHERE book_id = ? AND level >= ?`, bookID, level)
	if err != nil {
		return fmt.Errorf("删除 AI 摘要失败: %w", err)
	}
	return nil
}

func scanAISummary(s scanner) (*domain.AISummary, error) {
	var (
		m            domain.AISummary
		ok           int
		created, upd int64
	)
	if err := s.Scan(&m.ID, &m.BookID, &m.Level, &m.Ordinal, &m.ParentLevel, &m.ParentOrd,
		&m.ChapterFrom, &m.ChapterTo, &m.Content, &m.TokenCount, &m.Model, &m.SrcHash,
		&ok, &m.Error, &created, &upd); err != nil {
		return nil, err
	}
	m.OK = ok != 0
	m.CreatedAt = time.Unix(created, 0)
	m.UpdatedAt = time.Unix(upd, 0)
	return &m, nil
}

// ── 索引状态仓储 ────────────────────────────────────────────

// AIIndexStateRepo 实现 port.AIIndexStateRepository。
type AIIndexStateRepo struct {
	db *DB
}

// NewAIIndexStateRepo 创建索引进度仓储。
func NewAIIndexStateRepo(db *DB) *AIIndexStateRepo { return &AIIndexStateRepo{db: db} }

var _ port.AIIndexStateRepository = (*AIIndexStateRepo)(nil)

// Get 取索引状态。
func (r *AIIndexStateRepo) Get(ctx context.Context, bookID int64) (*domain.AIIndexState, error) {
	var (
		st  domain.AIIndexState
		upd int64
	)
	err := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT book_id, scope, chapter_from, chapter_to, status, chunk_count,
			emb_done, summary_done, summary_total, error, updated_at
		 FROM ai_index_state WHERE book_id = ?`, bookID).
		Scan(&st.BookID, &st.Scope, &st.ChapterFrom, &st.ChapterTo, &st.Status,
			&st.ChunkCount, &st.EmbDone, &st.SummaryDone, &st.SummaryTotal,
			&st.Error, &upd)
	if err != nil {
		return nil, normalizeError(err)
	}
	st.UpdatedAt = time.Unix(upd, 0)
	return &st, nil
}

// Put 写入或覆盖状态。
func (r *AIIndexStateRepo) Put(ctx context.Context, st *domain.AIIndexState) error {
	if st.BookID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	upd := st.UpdatedAt
	if upd.IsZero() {
		upd = time.Now()
	}
	const query = `INSERT INTO ai_index_state
		(book_id, scope, chapter_from, chapter_to, status, chunk_count, emb_done,
		 summary_done, summary_total, error, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(book_id) DO UPDATE SET
			scope=excluded.scope, chapter_from=excluded.chapter_from,
			chapter_to=excluded.chapter_to, status=excluded.status,
			chunk_count=excluded.chunk_count, emb_done=excluded.emb_done,
			summary_done=excluded.summary_done, summary_total=excluded.summary_total,
			error=excluded.error, updated_at=excluded.updated_at`
	_, err := r.db.q(ctx).ExecContext(ctx, query,
		st.BookID, st.Scope, st.ChapterFrom, st.ChapterTo, st.Status, st.ChunkCount,
		st.EmbDone, st.SummaryDone, st.SummaryTotal, st.Error, upd.Unix())
	if err != nil {
		return fmt.Errorf("写入 AI 索引状态失败: %w", err)
	}
	return nil
}

// Delete 删除状态。
func (r *AIIndexStateRepo) Delete(ctx context.Context, bookID int64) error {
	_, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM ai_index_state WHERE book_id = ?`, bookID)
	if err != nil {
		return fmt.Errorf("删除 AI 索引状态失败: %w", err)
	}
	return nil
}

// ── 会话仓储 ────────────────────────────────────────────────

// AIChatRepo 实现 port.AIChatRepository。
type AIChatRepo struct {
	db *DB
}

// NewAIChatRepo 创建 AI 会话仓储。
func NewAIChatRepo(db *DB) *AIChatRepo { return &AIChatRepo{db: db} }

var _ port.AIChatRepository = (*AIChatRepo)(nil)

// CreateChat 创建会话并回填 ID。
func (r *AIChatRepo) CreateChat(ctx context.Context, c *domain.AIChat) error {
	if c.BookID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	now := time.Now()
	if c.CreatedAt.IsZero() {
		c.CreatedAt = now
	}
	c.UpdatedAt = c.CreatedAt

	res, err := r.db.q(ctx).ExecContext(ctx,
		`INSERT INTO ai_chats (book_id, title, scope, model, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		c.BookID, c.Title, c.Scope, c.Model, c.CreatedAt.Unix(), c.UpdatedAt.Unix())
	if err != nil {
		return fmt.Errorf("创建 AI 会话失败: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return fmt.Errorf("读取会话 ID 失败: %w", err)
	}
	c.ID = id
	return nil
}

// GetChat 取会话。
func (r *AIChatRepo) GetChat(ctx context.Context, id int64) (*domain.AIChat, error) {
	var (
		c                domain.AIChat
		created, updated int64
	)
	err := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT id, book_id, title, scope, model, created_at, updated_at
		 FROM ai_chats WHERE id = ?`, id).
		Scan(&c.ID, &c.BookID, &c.Title, &c.Scope, &c.Model, &created, &updated)
	if err != nil {
		return nil, normalizeError(err)
	}
	c.CreatedAt = time.Unix(created, 0)
	c.UpdatedAt = time.Unix(updated, 0)
	return &c, nil
}

// ListChats 返回某本书的会话，按更新时间倒序。
func (r *AIChatRepo) ListChats(ctx context.Context, bookID int64) ([]*domain.AIChat, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx,
		`SELECT id, book_id, title, scope, model, created_at, updated_at
		 FROM ai_chats WHERE book_id = ? ORDER BY updated_at DESC, id DESC`, bookID)
	if err != nil {
		return nil, fmt.Errorf("查询 AI 会话失败: %w", err)
	}
	defer rows.Close()

	var out []*domain.AIChat
	for rows.Next() {
		var (
			c                domain.AIChat
			created, updated int64
		)
		if err := rows.Scan(&c.ID, &c.BookID, &c.Title, &c.Scope, &c.Model, &created, &updated); err != nil {
			return nil, fmt.Errorf("读取 AI 会话失败: %w", err)
		}
		c.CreatedAt = time.Unix(created, 0)
		c.UpdatedAt = time.Unix(updated, 0)
		out = append(out, &c)
	}
	return out, rows.Err()
}

// TouchChat 更新会话的更新时间。
func (r *AIChatRepo) TouchChat(ctx context.Context, id int64) error {
	_, err := r.db.q(ctx).ExecContext(ctx,
		`UPDATE ai_chats SET updated_at = ? WHERE id = ?`, time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("更新会话时间失败: %w", err)
	}
	return nil
}

// DeleteChat 删除会话及其消息。
func (r *AIChatRepo) DeleteChat(ctx context.Context, id int64) error {
	// 显式删消息：不依赖 foreign_keys 开关是否打开，避免残留孤儿行。
	return r.db.Do(ctx, func(ctx context.Context) error {
		if _, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM ai_messages WHERE chat_id = ?`, id); err != nil {
			return fmt.Errorf("删除会话消息失败: %w", err)
		}
		if _, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM ai_chats WHERE id = ?`, id); err != nil {
			return fmt.Errorf("删除会话失败: %w", err)
		}
		return nil
	})
}

// AddMessage 追加一条消息并回填 ID。
func (r *AIChatRepo) AddMessage(ctx context.Context, m *domain.AIMessage) error {
	if m.ChatID == 0 {
		return fmt.Errorf("%w: 缺少会话 ID", domain.ErrInvalidArgument)
	}
	now := time.Now()
	if m.CreatedAt.IsZero() {
		m.CreatedAt = now
	}
	refs := "[]"
	if len(m.Refs) > 0 {
		b, err := json.Marshal(m.Refs)
		if err != nil {
			return fmt.Errorf("序列化引用失败: %w", err)
		}
		refs = string(b)
	}
	res, err := r.db.q(ctx).ExecContext(ctx,
		`INSERT INTO ai_messages (chat_id, role, content, refs, created_at)
		 VALUES (?, ?, ?, ?, ?)`,
		m.ChatID, m.Role, m.Content, refs, m.CreatedAt.Unix())
	if err != nil {
		return fmt.Errorf("写入会话消息失败: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return fmt.Errorf("读取消息 ID 失败: %w", err)
	}
	m.ID = id
	return nil
}

// Messages 返回会话的全部消息。
func (r *AIChatRepo) Messages(ctx context.Context, chatID int64) ([]*domain.AIMessage, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx,
		`SELECT id, chat_id, role, content, refs, created_at
		 FROM ai_messages WHERE chat_id = ? ORDER BY id ASC`, chatID)
	if err != nil {
		return nil, fmt.Errorf("查询会话消息失败: %w", err)
	}
	defer rows.Close()

	var out []*domain.AIMessage
	for rows.Next() {
		var (
			m       domain.AIMessage
			refs    string
			created int64
		)
		if err := rows.Scan(&m.ID, &m.ChatID, &m.Role, &m.Content, &refs, &created); err != nil {
			return nil, fmt.Errorf("读取会话消息失败: %w", err)
		}
		if refs != "" && refs != "[]" {
			var list []domain.AIRef
			if err := json.Unmarshal([]byte(refs), &list); err == nil {
				m.Refs = list
			}
		}
		m.CreatedAt = time.Unix(created, 0)
		out = append(out, &m)
	}
	return out, rows.Err()
}

// boolInt 把布尔转成 sqlite 的 0/1。
func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
