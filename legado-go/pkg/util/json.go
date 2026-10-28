package util

import "regexp"

// bareJSONKey 匹配 JSON 里的裸键（{"a":1, b:2} 中的 b）
var bareJSONKey = regexp.MustCompile(`([{,]\s*)([A-Za-z_][\w]*)\s*:`)

// RelaxJSONKeys 给裸键补双引号，用于解析书源里手写、不严格的 JSON
// （header、@put:{}、url 选项等）。已经是合法 JSON 时调用也安全。
func RelaxJSONKeys(s string) string {
	return bareJSONKey.ReplaceAllString(s, `$1"$2":`)
}
