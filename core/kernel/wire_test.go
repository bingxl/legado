package kernel

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// newTestRegistry 造一个只含被测方法的注册表。
func newTestRegistry(t *testing.T) *Registry {
	t.Helper()
	return NewRegistry()
}

func decodeEnvelope(t *testing.T, raw []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("响应不是合法 JSON: %v（原文 %s）", err, raw)
	}
	return m
}

func TestHandleSuccess(t *testing.T) {
	r := newTestRegistry(t)
	r.Method("Demo.Add", func(ctx context.Context, args []json.RawMessage) (any, error) {
		var a, b int
		_ = json.Unmarshal(args[0], &a)
		_ = json.Unmarshal(args[1], &b)
		return a + b, nil
	})

	out := decodeEnvelope(t, r.Handle(context.Background(),
		[]byte(`{"id":7,"method":"Demo.Add","args":[2,3]}`)))
	if out["ok"] != true {
		t.Fatalf("ok 应为 true: %v", out)
	}
	if out["id"] != float64(7) {
		t.Errorf("id 没回传: %v", out["id"])
	}
	if out["data"] != float64(5) {
		t.Errorf("data = %v，期望 5", out["data"])
	}
}

// 未知方法要给出 NOT_FOUND 码而不是裸 error 字符串——
// Dart 侧按 code 分支处理（例如 NOT_FOUND 时回退到旧接口）。
func TestHandleUnknownMethod(t *testing.T) {
	r := newTestRegistry(t)
	out := decodeEnvelope(t, r.Handle(context.Background(), []byte(`{"method":"Nope.X"}`)))
	if out["ok"] != false {
		t.Fatalf("ok 应为 false: %v", out)
	}
	errObj, ok := out["err"].(map[string]any)
	if !ok {
		t.Fatalf("缺少 err 对象: %v", out)
	}
	if errObj["code"] != string(CodeNotFound) {
		t.Errorf("code = %v，期望 %v", errObj["code"], CodeNotFound)
	}
}

func TestHandleInvalidJSON(t *testing.T) {
	r := newTestRegistry(t)
	out := decodeEnvelope(t, r.Handle(context.Background(), []byte(`{`)))
	if out["ok"] != false {
		t.Fatalf("ok 应为 false: %v", out)
	}
	errObj := out["err"].(map[string]any)
	if errObj["code"] != string(CodeInvalid) {
		t.Errorf("code = %v，期望 %v", errObj["code"], CodeInvalid)
	}
}

func TestHandleMissingMethod(t *testing.T) {
	r := newTestRegistry(t)
	out := decodeEnvelope(t, r.Handle(context.Background(), []byte(`{"id":1,"args":[]}`)))
	if out["ok"] != false {
		t.Fatalf("缺 method 应当失败: %v", out)
	}
}

// 业务错误要带上原始错误文本，方便 UI 直接展示。
func TestHandleBusinessError(t *testing.T) {
	r := newTestRegistry(t)
	r.Method("Demo.Fail", func(ctx context.Context, args []json.RawMessage) (any, error) {
		return nil, Ef(CodeInvalid, "参数不对：%s", "x")
	})
	out := decodeEnvelope(t, r.Handle(context.Background(), []byte(`{"method":"Demo.Fail"}`)))
	errObj := out["err"].(map[string]any)
	if errObj["code"] != string(CodeInvalid) {
		t.Errorf("code = %v", errObj["code"])
	}
	if !strings.Contains(errObj["msg"].(string), "参数不对") {
		t.Errorf("msg 丢了原文: %v", errObj["msg"])
	}
}

// handler panic 必须被信封化。
//
// 这条最关键：c-shared 与 gomobile 是进程内宿主，panic 会把整个 App 带走；
// HTTP 宿主有 net/http 兜底，行为不一致时就变成「桌面没事、安卓闪退」。
func TestHandleRecoversPanic(t *testing.T) {
	r := newTestRegistry(t)
	r.Method("Demo.Boom", func(ctx context.Context, args []json.RawMessage) (any, error) {
		var m map[string]string
		// 故意解引用 nil map 造成 panic
		m["x"] = "y"
		return nil, nil
	})

	out := decodeEnvelope(t, r.Handle(context.Background(), []byte(`{"id":9,"method":"Demo.Boom"}`)))
	if out["ok"] != false {
		t.Fatalf("panic 应当转成失败信封: %v", out)
	}
	if out["id"] != float64(9) {
		t.Errorf("panic 路径也要回传 id: %v", out["id"])
	}
	errObj := out["err"].(map[string]any)
	if errObj["code"] != string(CodeInternal) {
		t.Errorf("code = %v，期望 %v", errObj["code"], CodeInternal)
	}
}

// AsError 要能把普通 error 归类，否则所有失败都成 INTERNAL。
func TestAsErrorSentinels(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{context.DeadlineExceeded, string(CodeNetTimeout)},
		{errors.New("随便一个错"), string(CodeInternal)},
	}
	for _, c := range cases {
		if got := AsError(c.err).Code; got != c.want {
			t.Errorf("AsError(%v).Code = %v，期望 %v", c.err, got, c.want)
		}
	}
}
