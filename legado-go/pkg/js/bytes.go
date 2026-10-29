package js

import (
	"fmt"

	"github.com/dop251/goja"
)

// —— Java byte[] 在 JS 里的替身 ——
//
// 原版 legado 的 JS 跑在 Rhino 上，`java.base64DecodeToByteArray()` 之类返回的是
// Java byte[]，Rhino 把它包成 NativeJavaArray：既能 `buf.length`，也能 `buf[i]`。
// Go 侧没有 Java，`vm.ToValue([]byte)` 会变成 ArrayBuffer（只有 byteLength、不可索引），
// 书源里 `buf.length` 会拿到 undefined，后续按下标处理的逻辑直接崩。
//
// 因此统一用「数字数组」表示字节数组：length / 下标 / 传参都与 Rhino 一致；
// 反向转换由 toBytes 完成，它认得数字数组、ArrayBuffer、TypedArray 和字符串。

// toJSBytes 把 Go 字节切片转成 JS 里可索引的数字数组（模拟 Java byte[]）。
func toJSBytes(vm *goja.Runtime, b []byte) goja.Value {
	arr := make([]any, len(b))
	for i, c := range b {
		arr[i] = int64(c)
	}
	return vm.ToValue(arr)
}

// toBytes 把 JS 值转成 Go 字节切片。
//
// 覆盖书源里常见的几种形态：
//   - 数字数组（本项目 toJSBytes 的产物，也是 Rhino byte[] 的等价物）
//   - ArrayBuffer / TypedArray（java.strToBytes、旧版实现返回的值）
//   - 字符串（按 UTF-8 取字节，等价于 Java 的 String.getBytes()）
func toBytes(v goja.Value) []byte {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return nil
	}
	switch t := v.Export().(type) {
	case goja.ArrayBuffer:
		return t.Bytes()
	case []byte:
		return t
	case string:
		return []byte(t)
	case []any:
		out := make([]byte, 0, len(t))
		for _, e := range t {
			out = append(out, byte(toInt(e)))
		}
		return out
	case []int64:
		out := make([]byte, 0, len(t))
		for _, e := range t {
			out = append(out, byte(e))
		}
		return out
	case int64:
		return []byte{byte(t)}
	}
	// 兜底：当作字符串。宁可拿到一份可用的字节，也不要让规则整条失败。
	return []byte(fmt.Sprint(v.Export()))
}

// bytesArg 取第 n 个参数并转成字节切片。
func bytesArg(call goja.FunctionCall, n int) []byte {
	if len(call.Arguments) <= n {
		return nil
	}
	return toBytes(call.Argument(n))
}

// newPackagesObject 模拟 Rhino/Nashorn 的 `Packages.*` 宿主对象。
//
// 书源里常用它直接调 Java 标准库，例如漫蛙漫画：
//
//	var Arrays = Packages.java.util.Arrays
//	var iv = Arrays.copyOfRange(buf, 0, 16)
//
// 这里只实现书源实际用得到的部分（java.util.Arrays），
// 其余类名一律返回 undefined —— 与其伪造一个不能用的类，不如让脚本显式报错。
func newPackagesObject(vm *goja.Runtime) *goja.Object {
	pkgs := vm.NewObject()
	java := vm.NewObject()
	jutil := vm.NewObject()
	jutil.Set("Arrays", newJavaArraysClass(vm))
	java.Set("util", jutil)
	pkgs.Set("java", java)
	return pkgs
}

// newJavaArraysClass 提供 java.util.Arrays 的静态方法子集。
func newJavaArraysClass(vm *goja.Runtime) *goja.Object {
	class := vm.NewObject()

	// Arrays.copyOfRange(byte[] original, int from, int to)
	class.Set("copyOfRange", func(call goja.FunctionCall) goja.Value {
		src := bytesArg(call, 0)
		from := toInt(exportValue(call.Argument(1)))
		to := toInt(exportValue(call.Argument(2)))
		out := copyOfRange(src, from, to)
		return toJSBytes(vm, out)
	})

	// Arrays.copyOf(byte[] original, int newLength)
	class.Set("copyOf", func(call goja.FunctionCall) goja.Value {
		src := bytesArg(call, 0)
		n := toInt(exportValue(call.Argument(1)))
		if n < 0 {
			n = 0
		}
		out := make([]byte, n)
		copy(out, src)
		return toJSBytes(vm, out)
	})

	// Arrays.toString(byte[]) —— 个别源拿它做调试输出
	class.Set("toString", func(call goja.FunctionCall) goja.Value {
		src := bytesArg(call, 0)
		s := make([]string, len(src))
		for i, c := range src {
			s[i] = fmt.Sprint(c)
		}
		out := "["
		for i, p := range s {
			if i > 0 {
				out += ", "
			}
			out += p
		}
		return vm.ToValue(out + "]")
	})
	return class
}

// copyOfRange 对齐 JDK 语义：越界时用 0 补足，from > to 视为非法返回空。
func copyOfRange(src []byte, from, to int) []byte {
	if from < 0 {
		from = 0
	}
	if to < from {
		return nil
	}
	if from >= len(src) {
		return make([]byte, to-from)
	}
	out := make([]byte, to-from)
	copy(out, src[from:min(to, len(src))])
	return out
}
