package rule

import "encoding/json"

// NativeObject 标记「由 JS 返回」的对象，对应 legado 中的
// org.mozilla.javascript.NativeObject。
//
// 为什么要单独一个类型：
// legado 的 getString / getStringList 只对 NativeObject 走「键值直接访问」分支
// （把规则串当作 key 直接取值），而 JSON 解析产生的普通对象仍走正常规则解析。
// Go 里二者都可以用 map[string]any 表示，若不区分，JSON 内容就会被误判为
// JS 对象，导致 $.xxx 之类的 JSONPath 规则取不到值。
type NativeObject struct {
	M map[string]any
}

// NewNativeObject 包装 JS 返回的对象
func NewNativeObject(m map[string]any) *NativeObject {
	if m == nil {
		m = map[string]any{}
	}
	return &NativeObject{M: m}
}

// Get 按键取值
func (n *NativeObject) Get(key string) (any, bool) {
	if n == nil || n.M == nil {
		return nil, false
	}
	v, ok := n.M[key]
	return v, ok
}

// Keys 所有键名（按 JSON 序列化后的顺序不保证，仅用于调试/容错）
func (n *NativeObject) Keys() []string {
	if n == nil {
		return nil
	}
	out := make([]string, 0, len(n.M))
	for k := range n.M {
		out = append(out, k)
	}
	return out
}

// String 序列化为 JSON，便于规则取值后的字符串化
func (n *NativeObject) String() string {
	if n == nil {
		return ""
	}
	b, _ := json.Marshal(n.M)
	return string(b)
}

// MarshalJSON 让 *NativeObject 可被直接序列化
func (n *NativeObject) MarshalJSON() ([]byte, error) {
	if n == nil {
		return []byte("null"), nil
	}
	return json.Marshal(n.M)
}

// wrapNative 把 JS 返回值中的对象标记为 NativeObject
func wrapNative(v any) any {
	switch t := v.(type) {
	case *NativeObject:
		return t
	case map[string]any:
		m := make(map[string]any, len(t))
		for k, x := range t {
			m[k] = wrapNative(x)
		}
		return NewNativeObject(m)
	case []any:
		out := make([]any, len(t))
		for i, x := range t {
			out[i] = wrapNative(x)
		}
		return out
	}
	return v
}

// unwrapNative 还原为普通 Go 值（注入 JS、序列化时使用）
func unwrapNative(v any) any {
	switch t := v.(type) {
	case *NativeObject:
		if t == nil {
			return nil
		}
		m := make(map[string]any, len(t.M))
		for k, x := range t.M {
			m[k] = unwrapNative(x)
		}
		return m
	case []any:
		out := make([]any, len(t))
		for i, x := range t {
			out[i] = unwrapNative(x)
		}
		return out
	}
	return v
}
