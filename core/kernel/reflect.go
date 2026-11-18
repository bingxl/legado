package kernel

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
)

var (
	ctxType = reflect.TypeOf((*context.Context)(nil)).Elem()
	errType = reflect.TypeOf((*error)(nil)).Elem()
)

// RegisterService 把一个服务对象的全部导出方法注册为 `<domain>.<Method>`。
//
// 这是迁移期的关键工具：Wails 版的 `desktop/api/*` 已经是「薄壳 + 接口注入」，
// 用反射适配后 100+ 个方法零改动即可供 CLI / FFI / HTTP 使用，
// 避免为了新宿主把业务包装层重写一遍。
//
// 约定：第一个参数若是 context.Context 则自动注入；最后一个返回值若是 error 则视为错误。
// 参数一律按**位置**从 JSON 数组解出（Go 反射不提供参数名）。
func RegisterService(r *Registry, domain string, svc any) int {
	v := reflect.ValueOf(svc)
	if !v.IsValid() {
		return 0
	}
	t := v.Type()
	n := 0
	for i := 0; i < t.NumMethod(); i++ {
		m := t.Method(i)
		if !m.IsExported() {
			continue
		}
		if skipMethod(m.Name, m.Type) {
			continue
		}
		h, meta := makeHandler(v.Method(i), domain, m.Name)
		r.Add(meta)
		_ = h
		n++
	}
	return n
}

// lifecycleMethods 是服务对象的生命周期/宿主方法，不属于控制面能力。
var lifecycleMethods = map[string]bool{
	"Close": true, "StopAll": true, "StopImport": true, "ServeHTTP": true,
	"Start": true, "Stop": true, "Reload": true,
}

// skipMethod 过滤掉无法经 JSON 传输的方法（含 http.ResponseWriter 等）、
// 生命周期方法，以及链式 builder（返回自身类型，如 WithCache）。
func skipMethod(name string, t reflect.Type) bool {
	if lifecycleMethods[name] {
		return true
	}
	// 链式构造：接收者是第 0 个参数（receiver），若首个返回值与之一致则跳过。
	if t.NumOut() > 0 && t.NumIn() > 0 && t.Out(0) == t.In(0) {
		return true
	}
	for i := 0; i < t.NumIn(); i++ {
		it := t.In(i)
		if it.Kind() == reflect.Func || it.Kind() == reflect.Chan || it.Kind() == reflect.UnsafePointer {
			return true
		}
		s := it.String()
		if strings.Contains(s, "http.ResponseWriter") || strings.Contains(s, "http.Request") {
			return true
		}
	}
	return false
}

// makeHandler 生成反射分发器，并返回方法元数据。
func makeHandler(m reflect.Value, domain, name string) (Handler, *Method) {
	t := m.Type()
	hasCtx := t.NumIn() > 0 && t.In(0).Implements(ctxType)
	offset := 0
	if hasCtx {
		offset = 1
	}
	arity := t.NumIn() - offset

	paramTypes := make([]string, 0, arity)
	for i := 0; i < arity; i++ {
		paramTypes = append(paramTypes, t.In(i+offset).String())
	}

	// 返回值：末尾若是 error 则剥离，其余作为结果。
	numOut := t.NumOut()
	hasErr := numOut > 0 && t.Out(numOut-1).Implements(errType)
	resultN := numOut
	if hasErr {
		resultN--
	}
	resultTypes := make([]string, 0, resultN)
	for i := 0; i < resultN; i++ {
		resultTypes = append(resultTypes, t.Out(i).String())
	}

	meta := &Method{
		Name:        domain + "." + name,
		Arity:       arity,
		ParamTypes:  paramTypes,
		ResultTypes: resultTypes,
	}

	h := func(ctx context.Context, args []json.RawMessage) (res any, err error) {
		// 方法内部 panic 不能让宿主进程挂掉：转成可读错误。
		defer func() {
			if rec := recover(); rec != nil {
				err = Ef(CodeInternal, "%s panic: %v", meta.Name, rec)
			}
		}()

		in := make([]reflect.Value, t.NumIn())
		if hasCtx {
			in[0] = reflect.ValueOf(ctx)
		}
		for i := 0; i < arity; i++ {
			pt := t.In(i + offset)
			holder := reflect.New(pt)
			if i < len(args) && len(args[i]) > 0 && string(args[i]) != "null" {
				if err := json.Unmarshal(args[i], holder.Interface()); err != nil {
					return nil, Ef(CodeInvalid, "%s 第 %d 个参数解析失败: %v", meta.Name, i+1, err)
				}
			}
			in[i+offset] = holder.Elem()
		}

		out := m.Call(in)
		if hasErr {
			if e := out[numOut-1]; !e.IsNil() {
				return nil, AsError(e.Interface().(error))
			}
		}
		switch resultN {
		case 0:
			return nil, nil
		case 1:
			return out[0].Interface(), nil
		default:
			vals := make([]any, 0, resultN)
			for i := 0; i < resultN; i++ {
				vals = append(vals, out[i].Interface())
			}
			return vals, nil
		}
	}
	meta.handler = h
	return h, meta
}

// DocOf 返回方法签名摘要，用于 `legado schema` 与排错。
func DocOf(m Method) string {
	return fmt.Sprintf("%s(%v) -> (%v)", m.Name, m.ParamTypes, m.ResultTypes)
}
