package app

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// stubSettings 模拟「从没保存过任何配置」的配置存储。
type stubSettings struct {
	port.SettingsStore
	raw string
	err error
}

func (s stubSettings) Get(context.Context, string) (string, error) { return s.raw, s.err }

// 全新安装时点「测试连接」，提示必须是「去填服务地址」，
// 而不是仓储层那句看不懂的「资源不存在」。
func TestWebDAVTestWithoutConfig(t *testing.T) {
	cases := []struct {
		name string
		cfg  stubSettings
	}{
		{"配置键不存在", stubSettings{err: domain.ErrNotFound}},
		{"配置值为空", stubSettings{raw: ""}},
		{"配置里没有地址", stubSettings{raw: `{"url":"","username":"u"}`}},
	}
	for _, c := range cases {
		svc := NewWebDAVService(c.cfg, nil, nil, "")
		err := svc.Test(context.Background())
		if err == nil {
			t.Fatalf("%s: 未配置时应报错", c.name)
		}
		if !errors.Is(err, domain.ErrNotConfigured) {
			t.Fatalf("%s: 错误类型应为 ErrNotConfigured，实际 %v", c.name, err)
		}
		if !strings.Contains(err.Error(), "WebDAV 服务地址") {
			t.Fatalf("%s: 提示应指明去填服务地址，实际 %q", c.name, err.Error())
		}
		if strings.Contains(err.Error(), "资源不存在") {
			t.Fatalf("%s: 不应把仓储错误直接抛给用户，实际 %q", c.name, err.Error())
		}
	}
}

// 未配置是正常初始状态：读配置要返回空视图，不能让页面一进来就弹错误。
func TestWebDAVGetConfigWithoutConfig(t *testing.T) {
	svc := NewWebDAVService(stubSettings{err: domain.ErrNotFound}, nil, nil, "")
	view, err := svc.GetConfig(context.Background())
	if err != nil {
		t.Fatalf("未配置时 GetConfig 不应报错: %v", err)
	}
	if view.URL != "" || view.Configured {
		t.Fatalf("未配置时应返回空视图: %+v", view)
	}
}
