package util

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf16"
)

// ParseLooseJSON 解析书源里手写的「宽松 JSON」，对齐 Gson 的 lenient 模式。
//
// 为什么需要它：书源里的内嵌 JSON 字段（exploreUrl、header、loginUi、
// @put:{}、URL 选项……）几乎都是人手写的，Kotlin 侧统一走 GSON，而 GSON
// 默认是 lenient 的——单引号字符串、裸键、裸值、注释、尾随逗号全都吃得下。
// Go 的 encoding/json 是严格模式，同一份书源搬过来会直接解析失败。
//
// 本函数只解析数据，**不执行任何 JS**：把 `[{title:'全部'}]` 当成数据读，
// 而不是丢进 JS 引擎求值。这样既能兼容，也不会让书源内容变成可执行代码。
//
// 支持范围（与 Gson lenient 对齐）：
//   - 单引号 / 双引号字符串，裸字符串值（如 `url: http://a.com/x`）
//   - 裸键（`{title:'x'}`）、尾随逗号、`//` 与 `/* */` 注释
//   - 数字、true/false/null/undefined（后两者转成 nil）
//
// 顶层可以是对象、数组或标量；解析失败返回 error，由调用方决定是否降级。
func ParseLooseJSON(s string) (any, error) {
	p := &looseJSONParser{src: s}
	p.skipSpace()
	v, err := p.parseValue()
	if err != nil {
		return nil, err
	}
	p.skipSpace()
	if p.i < len(p.src) {
		return nil, fmt.Errorf("宽松 JSON 解析后仍有多余内容（位置 %d）", p.i)
	}
	return v, nil
}

// UnmarshalLooseJSON 宽松解析后反序列化到 v（与 json.Unmarshal 用法一致）。
//
// 实现上借助一次 json.Marshal 中转：宽松语法只在「读」这一侧需要，
// 转成标准 JSON 后交给 encoding/json 处理类型映射与字段匹配，省得自己
// 再实现一套反射赋值。书源解析频率很低，这点开销可以忽略。
func UnmarshalLooseJSON(s string, v any) error {
	parsed, err := ParseLooseJSON(s)
	if err != nil {
		return err
	}
	b, err := json.Marshal(parsed)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

type looseJSONParser struct {
	src string
	i   int
}

// skipSpace 跳过空白、`//` 行注释与 `/* */` 块注释。
func (p *looseJSONParser) skipSpace() {
	for p.i < len(p.src) {
		switch p.src[p.i] {
		case ' ', '\t', '\r', '\n':
			p.i++
		case '/':
			if p.i+1 >= len(p.src) {
				return
			}
			switch p.src[p.i+1] {
			case '/':
				p.i += 2
				for p.i < len(p.src) && p.src[p.i] != '\n' {
					p.i++
				}
			case '*':
				p.i += 2
				for p.i+1 < len(p.src) && !(p.src[p.i] == '*' && p.src[p.i+1] == '/') {
					p.i++
				}
				if p.i+1 < len(p.src) {
					p.i += 2
				} else {
					p.i = len(p.src)
				}
			default:
				return
			}
		default:
			return
		}
	}
}

func (p *looseJSONParser) parseValue() (any, error) {
	p.skipSpace()
	if p.i >= len(p.src) {
		return nil, fmt.Errorf("宽松 JSON 意外结束")
	}
	switch c := p.src[p.i]; c {
	case '{':
		return p.parseObject()
	case '[':
		return p.parseArray()
	case '"', '\'':
		return p.parseString(c)
	}
	return p.parseBareValue()
}

// parseBareValue 读取裸值：数字、字面量，或未加引号的字符串。
//
// **不能把 `:` 当分隔符**——裸值常常是 URL（`http://a.com/x?a=1`）。
func (p *looseJSONParser) parseBareValue() (any, error) {
	start := p.i
	for p.i < len(p.src) {
		switch p.src[p.i] {
		case ',', '}', ']', ' ', '\t', '\r', '\n':
			goto done
		}
		p.i++
	}
done:
	tok := strings.TrimSpace(p.src[start:p.i])
	if tok == "" {
		return nil, fmt.Errorf("宽松 JSON 在位置 %d 缺少值", start)
	}
	switch tok {
	case "true":
		return true, nil
	case "false":
		return false, nil
	case "null", "undefined":
		return nil, nil
	}
	if f, err := strconv.ParseFloat(tok, 64); err == nil {
		return f, nil
	}
	// Gson lenient 把无法识别的裸值当成字符串，这里保持一致。
	return tok, nil
}

func (p *looseJSONParser) parseObject() (any, error) {
	p.i++ // {
	obj := map[string]any{}
	for {
		p.skipSpace()
		if p.i >= len(p.src) {
			return nil, fmt.Errorf("宽松 JSON 对象未闭合")
		}
		if p.src[p.i] == '}' {
			p.i++
			return obj, nil
		}
		key, err := p.parseKey()
		if err != nil {
			return nil, err
		}
		p.skipSpace()
		if p.i >= len(p.src) || p.src[p.i] != ':' {
			return nil, fmt.Errorf("宽松 JSON 对象的键 %q 后缺少 ':'", key)
		}
		p.i++
		v, err := p.parseValue()
		if err != nil {
			return nil, err
		}
		obj[key] = v
		p.skipSpace()
		if p.i < len(p.src) && p.src[p.i] == ',' {
			p.i++
			continue // 下一轮先 skipSpace，遇 '}' 即视为尾随逗号
		}
		if p.i < len(p.src) && p.src[p.i] == '}' {
			p.i++
			return obj, nil
		}
		return nil, fmt.Errorf("宽松 JSON 对象缺少 ',' 或 '}'")
	}
}

func (p *looseJSONParser) parseArray() (any, error) {
	p.i++ // [
	arr := []any{}
	for {
		p.skipSpace()
		if p.i >= len(p.src) {
			return nil, fmt.Errorf("宽松 JSON 数组未闭合")
		}
		if p.src[p.i] == ']' {
			p.i++
			return arr, nil
		}
		v, err := p.parseValue()
		if err != nil {
			return nil, err
		}
		arr = append(arr, v)
		p.skipSpace()
		if p.i < len(p.src) && p.src[p.i] == ',' {
			p.i++
			continue
		}
		if p.i < len(p.src) && p.src[p.i] == ']' {
			p.i++
			return arr, nil
		}
		return nil, fmt.Errorf("宽松 JSON 数组缺少 ',' 或 ']'")
	}
}

// parseKey 读对象键：可以是带引号的字符串，也可以是裸标识符。
func (p *looseJSONParser) parseKey() (string, error) {
	if c := p.src[p.i]; c == '"' || c == '\'' {
		return p.parseString(c)
	}
	start := p.i
	for p.i < len(p.src) {
		switch p.src[p.i] {
		case ':', ' ', '\t', '\r', '\n':
			return p.src[start:p.i], nil
		}
		p.i++
	}
	return p.src[start:p.i], nil
}

func (p *looseJSONParser) parseString(quote byte) (string, error) {
	p.i++ // 起始引号
	var b strings.Builder
	for p.i < len(p.src) {
		c := p.src[p.i]
		switch c {
		case quote:
			p.i++
			return b.String(), nil
		case '\\':
			p.i++
			if p.i >= len(p.src) {
				return "", fmt.Errorf("宽松 JSON 字符串以反斜杠结尾")
			}
			e := p.src[p.i]
			p.i++
			switch e {
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			case 'r':
				b.WriteByte('\r')
			case 'b':
				b.WriteByte('\b')
			case 'f':
				b.WriteByte('\f')
			case '/':
				b.WriteByte('/')
			case '\\':
				b.WriteByte('\\')
			case '"':
				b.WriteByte('"')
			case '\'':
				b.WriteByte('\'')
			case 'u':
				r, n, err := p.readUnicodeEscape()
				if err != nil {
					return "", err
				}
				b.WriteRune(r)
				p.i = n
			default:
				// 未知转义按原样保留（Gson 会吞掉反斜杠，这里更保守）。
				b.WriteByte('\\')
				b.WriteByte(e)
			}
		default:
			b.WriteByte(c)
			p.i++
		}
	}
	return "", fmt.Errorf("宽松 JSON 字符串未闭合")
}

// readUnicodeEscape 读取 \uXXXX（含代理对），返回 rune 与新的位置。
func (p *looseJSONParser) readUnicodeEscape() (rune, int, error) {
	// p.i 指向 'u' 之后
	if p.i+4 > len(p.src) {
		return 0, p.i, fmt.Errorf("宽松 JSON 的 \\u 转义不完整")
	}
	n, err := strconv.ParseUint(p.src[p.i:p.i+4], 16, 32)
	if err != nil {
		return 0, p.i, fmt.Errorf("宽松 JSON 的 \\u 转义非法: %q", p.src[p.i:p.i+4])
	}
	pos := p.i + 4
	r := rune(n)
	if utf16.IsSurrogate(r) && pos+6 <= len(p.src) && p.src[pos] == '\\' && p.src[pos+1] == 'u' {
		if n2, err2 := strconv.ParseUint(p.src[pos+2:pos+6], 16, 32); err2 == nil {
			if dec := utf16.DecodeRune(r, rune(n2)); dec != 0xFFFD {
				return dec, pos + 6, nil
			}
		}
	}
	return r, pos, nil
}
