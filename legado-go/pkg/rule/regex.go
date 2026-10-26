package rule

import (
	"regexp"
	"strings"

	"github.com/legado/legado-go/pkg/util"
)

// 本文件对齐 legado 的 AnalyzeByRegex.kt
// 多级正则以 && 分隔：除最后一级外，前面的正则用于"缩小范围"，最后一级提取分组。

var javaToGoReplacer = strings.NewReplacer(
	`\A`, `^`,
	`\Z`, `$`,
	`\z`, `$`,
	`\d`, `[0-9]`,
)

// compileReg Java 正则尽量兼容地编译为 Go 正则
func compileReg(pattern string) (*regexp.Regexp, error) {
	p := javaToGoReplacer.Replace(pattern)
	p = unescapeCharClass(p)
	re, err := regexp.Compile(p)
	if err != nil {
		// 回退：原样编译
		return regexp.Compile(pattern)
	}
	return re, nil
}

// unescapeCharClass 处理 Java 允许、Go 报错的字符类内多余转义
func unescapeCharClass(p string) string {
	// Go 的 RE2 不允许字符类内出现 \w \d \s 之外的无效转义，这里做最小修正
	var sb strings.Builder
	inClass := false
	for i := 0; i < len(p); i++ {
		c := p[i]
		switch c {
		case '[':
			inClass = true
			sb.WriteByte(c)
		case ']':
			inClass = false
			sb.WriteByte(c)
		case '\\':
			if i+1 < len(p) {
				n := p[i+1]
				if inClass && n == '\\' {
					sb.WriteByte('\\')
					sb.WriteByte('\\')
				} else {
					sb.WriteByte('\\')
					sb.WriteByte(n)
				}
				i++
			} else {
				sb.WriteByte(c)
			}
		default:
			sb.WriteByte(c)
		}
	}
	return sb.String()
}

// RegexGetElement 取第一个匹配的分组列表
func RegexGetElement(res string, regs []string, index int) []string {
	if index >= len(regs) || res == "" {
		return nil
	}
	re, err := compileReg(regs[index])
	if err != nil {
		return nil
	}
	loc := re.FindStringSubmatchIndex(res)
	if loc == nil {
		return nil
	}
	// 最后一级：返回所有分组
	if index+1 == len(regs) {
		info := make([]string, 0, re.NumSubexp()+1)
		for gi := 0; gi <= re.NumSubexp(); gi++ {
			if 2*gi+1 < len(loc) && loc[2*gi] >= 0 {
				info = append(info, res[loc[2*gi]:loc[2*gi+1]])
			} else {
				info = append(info, "")
			}
		}
		return info
	}
	// 非最后一级：拼接所有匹配，进入下一级
	var sb strings.Builder
	matches := re.FindAllString(res, -1)
	for _, m := range matches {
		sb.WriteString(m)
	}
	return RegexGetElement(sb.String(), regs, index+1)
}

// RegexGetElements 取所有匹配的分组列表
func RegexGetElements(res string, regs []string, index int) [][]string {
	out := [][]string{}
	if index >= len(regs) || res == "" {
		return out
	}
	re, err := compileReg(regs[index])
	if err != nil {
		return out
	}
	all := re.FindAllStringSubmatchIndex(res, -1)
	if len(all) == 0 {
		return out
	}
	if index+1 == len(regs) {
		for _, loc := range all {
			info := make([]string, 0, re.NumSubexp()+1)
			for gi := 0; gi <= re.NumSubexp(); gi++ {
				if 2*gi+1 < len(loc) && loc[2*gi] >= 0 {
					info = append(info, res[loc[2*gi]:loc[2*gi+1]])
				} else {
					info = append(info, "")
				}
			}
			out = append(out, info)
		}
		return out
	}
	var sb strings.Builder
	for _, loc := range all {
		sb.WriteString(res[loc[0]:loc[1]])
	}
	return RegexGetElements(sb.String(), regs, index+1)
}

// SplitRegexRules 按 && 拆分多级正则
func SplitRegexRules(rule string) []string {
	return util.SplitNotBlank(rule, "&&")
}
