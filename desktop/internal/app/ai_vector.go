package app

import (
	"math"
	"sort"

	"github.com/legado/desktop/internal/domain"
)

// 向量检索在这里是「暴力全扫」而非索引结构。
//
// 原因是 sqlite（modernc 纯 Go 实现）加载不了 sqlite-vec 扩展，
// 而自建 HNSW 之类的索引对单本书的规模属于过度设计：
// 一本书最多两万片，1024 维全扫约 2000 万次乘加，实测几十毫秒，
// 远低于一次模型调用的耗时。

// cosineSimilarity 计算两个向量的余弦相似度，取值 [-1, 1]。
//
// 维度不等或任一为零向量时返回 0：换过 embedding 模型后新旧向量维度不同，
// 此时静默给 0 分比 panic 或给出错误分数更安全，上层会另行提示重建索引。
func cosineSimilarity(a, b []float32) float64 {
	if len(a) != len(b) || len(a) == 0 {
		return 0
	}
	var dot, na, nb float64
	for i := range a {
		x := float64(a[i])
		y := float64(b[i])
		dot += x * y
		na += x * x
		nb += y * y
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return dot / (math.Sqrt(na) * math.Sqrt(nb))
}

// aiScored 是一条带分数的召回结果。
type aiScored struct {
	Chunk *domain.AIChunk
	Score float64
}

// vectorTopK 返回与 query 最相似的 k 条切片，按分数降序。
//
// 维度不匹配的切片会被跳过并计入 skipped——调用方据此判断是否该提示用户重建索引，
// 而不是悄悄用半套向量检索却给出看似正常的结果。
func vectorTopK(query []float32, chunks []*domain.AIChunk, k int) (top []aiScored, skipped int) {
	if k <= 0 {
		k = aiDefaultTopK
	}
	if len(query) == 0 {
		return nil, 0
	}

	scored := make([]aiScored, 0, len(chunks))
	for _, c := range chunks {
		if !c.HasVector() {
			continue
		}
		if len(c.Embedding) != len(query) {
			skipped++
			continue
		}
		scored = append(scored, aiScored{Chunk: c, Score: cosineSimilarity(query, c.Embedding)})
	}

	sort.SliceStable(scored, func(i, j int) bool { return scored[i].Score > scored[j].Score })
	if len(scored) > k {
		scored = scored[:k]
	}
	return scored, skipped
}

// aiDefaultTopK 是默认召回条数。
//
// 8~12 条是常见经验值：再少容易漏掉关键段落，再多会把上下文预算耗在
// 边缘相关的片子上，反而降低回答质量。
const aiDefaultTopK = 10
