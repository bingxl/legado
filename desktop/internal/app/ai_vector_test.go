package app

import (
	"math"
	"testing"

	"github.com/legado/desktop/internal/domain"
)

func almostEqual(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

func TestCosineSimilarity(t *testing.T) {
	cases := []struct {
		name string
		a, b []float32
		want float64
	}{
		{"相同向量", []float32{1, 2, 3}, []float32{1, 2, 3}, 1},
		{"缩放不变", []float32{1, 2, 3}, []float32{2, 4, 6}, 1},
		{"正交", []float32{1, 0}, []float32{0, 1}, 0},
		{"相反", []float32{1, 0}, []float32{-1, 0}, -1},
		{"零向量", []float32{0, 0}, []float32{1, 1}, 0},
		{"维度不等", []float32{1, 0}, []float32{1, 0, 0}, 0},
		{"空向量", nil, nil, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := cosineSimilarity(c.a, c.b); !almostEqual(got, c.want) {
				t.Fatalf("cosineSimilarity = %v, 期望 %v", got, c.want)
			}
		})
	}
}

func TestCosineSimilarityKnownAngle(t *testing.T) {
	// 45 度夹角，余弦应为 √2/2。
	got := cosineSimilarity([]float32{1, 0}, []float32{1, 1})
	if !almostEqual(got, math.Sqrt2/2) {
		t.Fatalf("45 度余弦 = %v, 期望 %v", got, math.Sqrt2/2)
	}
}

func TestVectorTopKRanksAndTruncates(t *testing.T) {
	chunks := []*domain.AIChunk{
		{ID: 1, Ordinal: 0, Embedding: []float32{1, 0}},  // 完全一致
		{ID: 2, Ordinal: 1, Embedding: []float32{1, 1}},  // 45 度
		{ID: 3, Ordinal: 2, Embedding: []float32{0, 1}},  // 正交
		{ID: 4, Ordinal: 3, Embedding: []float32{-1, 0}}, // 相反
	}
	top, skipped := vectorTopK([]float32{1, 0}, chunks, 2)
	if skipped != 0 {
		t.Fatalf("不应有跳过，实际 %d", skipped)
	}
	if len(top) != 2 {
		t.Fatalf("应返回 2 条，实际 %d", len(top))
	}
	if top[0].Chunk.ID != 1 || !almostEqual(top[0].Score, 1) {
		t.Fatalf("首位应是完全一致的那条: %d %v", top[0].Chunk.ID, top[0].Score)
	}
	if top[1].Chunk.ID != 2 {
		t.Fatalf("次位应是 45 度那条，实际 %d", top[1].Chunk.ID)
	}
}

func TestVectorTopKReturnsAllWhenFewerThanK(t *testing.T) {
	chunks := []*domain.AIChunk{{ID: 1, Embedding: []float32{1, 0}}}
	top, _ := vectorTopK([]float32{1, 0}, chunks, 10)
	if len(top) != 1 {
		t.Fatalf("应返回全部 1 条，实际 %d", len(top))
	}
}

func TestVectorTopKDefaultK(t *testing.T) {
	var chunks []*domain.AIChunk
	for i := 0; i < aiDefaultTopK+5; i++ {
		chunks = append(chunks, &domain.AIChunk{
			ID: int64(i), Embedding: []float32{float32(i), 1},
		})
	}
	top, _ := vectorTopK([]float32{1, 1}, chunks, 0)
	if len(top) != aiDefaultTopK {
		t.Fatalf("k<=0 时应落到默认 %d，实际 %d", aiDefaultTopK, len(top))
	}
}

func TestVectorTopKCountsDimensionMismatch(t *testing.T) {
	// 换过 embedding 模型后旧向量维度不同，必须能被发现并提示重建索引，
	// 而不是静默地只用一半数据给出"看起来正常"的答案。
	chunks := []*domain.AIChunk{
		{ID: 1, Embedding: []float32{1, 0, 0}},
		{ID: 2, Embedding: []float32{1, 0}}, // 旧模型，2 维
	}
	top, skipped := vectorTopK([]float32{1, 0, 0}, chunks, 5)
	if skipped != 1 {
		t.Fatalf("应统计到 1 条维度不符，实际 %d", skipped)
	}
	if len(top) != 1 || top[0].Chunk.ID != 1 {
		t.Fatalf("结果应只含维度匹配的那条: %+v", top)
	}
}

func TestVectorTopKIgnoresChunksWithoutVector(t *testing.T) {
	chunks := []*domain.AIChunk{
		{ID: 1, Embedding: []float32{1, 0}},
		{ID: 2}, // 未向量化
	}
	top, skipped := vectorTopK([]float32{1, 0}, chunks, 5)
	if len(top) != 1 {
		t.Fatalf("未向量化的切片不该参与排序，实际返回 %d 条", len(top))
	}
	if skipped != 0 {
		t.Fatalf("未向量化不算维度不符，skipped = %d", skipped)
	}
}

func TestVectorTopKEmptyQuery(t *testing.T) {
	chunks := []*domain.AIChunk{{ID: 1, Embedding: []float32{1, 0}}}
	top, _ := vectorTopK(nil, chunks, 5)
	if len(top) != 0 {
		t.Fatalf("空查询应返回空，实际 %d", len(top))
	}
}
