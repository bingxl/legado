package domain

import "testing"

func TestAIConfigConfigured(t *testing.T) {
	cases := []struct {
		name string
		cfg  AIConfig
		want bool
	}{
		{"空配置", AIConfig{}, false},
		{"只有 BaseURL", AIConfig{BaseURL: "https://api.x.com/v1"}, false},
		{"只有 Model", AIConfig{Model: "gpt-4o"}, false},
		{"完整", AIConfig{BaseURL: "https://api.x.com/v1", Model: "gpt-4o"}, true},
		{"空白字符不算有效", AIConfig{BaseURL: "   ", Model: "gpt-4o"}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.cfg.Configured(); got != c.want {
				t.Fatalf("Configured() = %v, want %v", got, c.want)
			}
		})
	}
}

func TestAIConfigEmbeddingEndpointFallsBack(t *testing.T) {
	// 未单独配 embedding 地址时应回落到 chat 地址，并去掉结尾斜杠。
	cfg := AIConfig{BaseURL: "https://api.deepseek.com/v1/"}
	if got := cfg.EmbeddingEndpoint(); got != "https://api.deepseek.com/v1" {
		t.Fatalf("回退地址 = %q", got)
	}

	// 单独配了 embedding 地址时优先用它。
	cfg.EmbeddingBaseURL = "https://embed.x.com/v1//"
	if got := cfg.EmbeddingEndpoint(); got != "https://embed.x.com/v1" {
		t.Fatalf("独立地址 = %q", got)
	}
}

func TestAIConfigHasEmbedding(t *testing.T) {
	// 典型场景：配了 DeepSeek（无 embedding 接口），必须判定为不可用，
	// 否则上层会去调一个不存在的端点。
	cfg := AIConfig{BaseURL: "https://api.deepseek.com/v1", Model: "deepseek-chat"}
	if cfg.HasEmbedding() {
		t.Fatal("未配 embedding 模型时应为 false")
	}

	cfg.EmbeddingModel = "text-embedding-3-small"
	if !cfg.HasEmbedding() {
		t.Fatal("配了模型且地址可用时应为 true")
	}

	// 地址整体缺失时即便填了模型也不可用。
	cfg.BaseURL = ""
	cfg.EmbeddingBaseURL = ""
	if cfg.HasEmbedding() {
		t.Fatal("无地址时应为 false")
	}
}
