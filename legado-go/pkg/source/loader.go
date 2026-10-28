package source

import (
	"encoding/json"
	"fmt"
	neturl "net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/legado/legado-go/pkg/model"
)

// LoadFile 从单个文件加载书源（支持 JSON 数组 / 单个对象 / 多对象拼接 / 含杂文本）
func LoadFile(path string) ([]*model.BookSource, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	list, err := ParseBytes(b)
	if err != nil {
		return nil, err
	}
	// 记下文件名，供 -source 按文件名选源、报错时提示来源
	name := filepath.Base(path)
	for _, s := range list {
		s.FileName = name
	}
	return list, nil
}

// ParseBytes 解析书源内容
func ParseBytes(b []byte) ([]*model.BookSource, error) {
	s := strings.TrimSpace(string(b))
	if s == "" {
		return nil, fmt.Errorf("内容为空")
	}
	// 1. JSON 数组
	var arr []*model.BookSource
	if err := json.Unmarshal([]byte(s), &arr); err == nil && len(arr) > 0 {
		return dedupe(arr), nil
	}
	// 2. JSON 对象
	var one model.BookSource
	if err := json.Unmarshal([]byte(s), &one); err == nil && one.BookSourceUrl != "" {
		return []*model.BookSource{&one}, nil
	}
	// 3. 暴力扫描顶层 {...} 对象
	out := make([]*model.BookSource, 0)
	for _, obj := range scanJSONObjects(s) {
		var src model.BookSource
		if err := json.Unmarshal([]byte(obj), &src); err != nil {
			continue
		}
		if src.BookSourceUrl != "" {
			out = append(out, &src)
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("未解析到任何书源")
	}
	return dedupe(out), nil
}

// scanJSONObjects 扫描字符串中所有顶层平衡的 {...}（忽略字符串内的花括号）
func scanJSONObjects(s string) []string {
	var out []string
	depth := 0
	start := -1
	inStr := false
	esc := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if esc {
			esc = false
			continue
		}
		if inStr {
			switch c {
			case '\\':
				esc = true
			case '"':
				inStr = false
			}
			continue
		}
		switch c {
		case '"':
			inStr = true
		case '{':
			if depth == 0 {
				start = i
			}
			depth++
		case '}':
			if depth > 0 {
				depth--
			}
			if depth == 0 && start >= 0 {
				out = append(out, s[start:i+1])
				start = -1
			}
		}
	}
	return out
}

func dedupe(list []*model.BookSource) []*model.BookSource {
	seen := map[string]bool{}
	out := make([]*model.BookSource, 0, len(list))
	for _, s := range list {
		if s.BookSourceUrl == "" || seen[s.BookSourceUrl] {
			continue
		}
		seen[s.BookSourceUrl] = true
		out = append(out, s)
	}
	return out
}

// LoadDir 从指定文件夹加载全部书源（递归，含 .json/.txt）
func LoadDir(dir string) ([]*model.BookSource, []error) {
	var all []*model.BookSource
	var errs []error
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, []error{fmt.Errorf("书源目录不存在: %s", dir)}
		}
		return nil, []error{fmt.Errorf("读取书源目录 %s 失败: %w", dir, err)}
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	slices.Sort(names)
	for _, name := range names {
		full := filepath.Join(dir, name)
		info, err := os.Stat(full)
		if err != nil {
			continue
		}
		if info.IsDir() {
			sub, subErr := LoadDir(full)
			all = append(all, sub...)
			errs = append(errs, subErr...)
			continue
		}
		ext := strings.ToLower(filepath.Ext(name))
		if ext != ".json" && ext != ".txt" {
			continue
		}
		list, err := LoadFile(full)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", name, err))
			continue
		}
		for i := range list {
			if list[i].BookSourceGroup == "" {
				list[i].BookSourceGroup = strings.TrimSuffix(name, filepath.Ext(name))
			}
		}
		all = append(all, list...)
	}
	return dedupe(all), errs
}

// Find 按 key 查找书源，返回最优匹配；key 为空时返回第一个书源。
//
// 支持写法（按优先级，命中某一级即返回该级全部候选）：
//  1. 序号：`2` 或 `#2`（从 1 开始，对应 list 命令输出）
//  2. bookSourceUrl 全等（忽略大小写与末尾 `/`）
//  3. bookSourceName 全等（忽略大小写）
//  4. 文件名全等：`kantianxia.json` 或 `kantianxia`
//  5. 书籍详情页 URL 命中 bookUrlPattern
//  6. 域名匹配：key 的 host 与 bookSourceUrl 的 host 相同（忽略 www. 与端口）
//  7. bookSourceUrl 子串
//  8. bookSourceName 子串
//  9. 文件名子串
//  10. bookSourceGroup 子串
//
// 需要知道是否有多个候选时用 MatchAll。
func Find(list []*model.BookSource, key string) *model.BookSource {
	if m := MatchAll(list, key); len(m) > 0 {
		return m[0]
	}
	return nil
}

// MatchAll 返回某一优先级下的全部匹配（顺序与传入列表一致）；无匹配返回 nil。
func MatchAll(list []*model.BookSource, key string) []*model.BookSource {
	key = strings.TrimSpace(key)
	if key == "" {
		if len(list) == 0 {
			return nil
		}
		return list[:1]
	}
	// 1. 序号
	if i, ok := parseOrdinal(key, len(list)); ok {
		return []*model.BookSource{list[i]}
	}

	lk := strings.ToLower(key)
	trimURL := func(s string) string { return strings.TrimRight(strings.ToLower(strings.TrimSpace(s)), "/") }
	likeURL := looksLikeURL(key)

	// 2. bookSourceUrl 全等
	if m := filter(list, func(s *model.BookSource) bool {
		return trimURL(s.BookSourceUrl) == strings.TrimRight(lk, "/")
	}); len(m) > 0 {
		return m
	}
	// 3. 名称全等
	if m := filter(list, func(s *model.BookSource) bool {
		return strings.EqualFold(strings.TrimSpace(s.BookSourceName), key)
	}); len(m) > 0 {
		return m
	}
	// 4. 文件名全等（带或不带扩展名）
	if m := filter(list, func(s *model.BookSource) bool {
		return matchFileName(s.FileName, key)
	}); len(m) > 0 {
		return m
	}
	if likeURL {
		// 5. 详情页 URL 命中 bookUrlPattern
		if m := filter(list, func(s *model.BookSource) bool {
			if s.BookUrlPattern == "" {
				return false
			}
			re, err := regexp.Compile(s.BookUrlPattern)
			return err == nil && re.MatchString(key)
		}); len(m) > 0 {
			return m
		}
		// 6. 域名匹配
		if kh := hostOf(key); kh != "" {
			if m := filter(list, func(s *model.BookSource) bool {
				return hostOf(s.BookSourceUrl) == kh
			}); len(m) > 0 {
				return m
			}
		}
	}

	// 7~10. 子串匹配（URL / 名称 / 文件名 / 分组）
	if m := filter(list, func(s *model.BookSource) bool {
		return strings.Contains(strings.ToLower(s.BookSourceUrl), lk)
	}); len(m) > 0 {
		return m
	}
	if m := filter(list, func(s *model.BookSource) bool {
		return strings.Contains(strings.ToLower(s.BookSourceName), lk)
	}); len(m) > 0 {
		return m
	}
	if m := filter(list, func(s *model.BookSource) bool {
		return strings.Contains(strings.ToLower(s.FileName), lk)
	}); len(m) > 0 {
		return m
	}
	return filter(list, func(s *model.BookSource) bool {
		return strings.Contains(strings.ToLower(s.BookSourceGroup), lk)
	})
}

func filter(list []*model.BookSource, keep func(*model.BookSource) bool) []*model.BookSource {
	var out []*model.BookSource
	for _, s := range list {
		if keep(s) {
			out = append(out, s)
		}
	}
	return out
}

// parseOrdinal 解析 `2` / `#2` 这样的 1 起始序号
func parseOrdinal(key string, n int) (int, bool) {
	s := strings.TrimPrefix(strings.TrimSpace(key), "#")
	if s == "" {
		return 0, false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	i, err := strconv.Atoi(s)
	if err != nil || i < 1 || i > n {
		return 0, false
	}
	return i - 1, true
}

// matchFileName 比较文件名：kantianxia.json / kantianxia 都能命中 kantianxia.json
func matchFileName(fileName, key string) bool {
	if fileName == "" {
		return false
	}
	fn := strings.ToLower(fileName)
	k := strings.ToLower(strings.TrimSpace(key))
	k = strings.TrimPrefix(k, "file://")
	if i := strings.LastIndexAny(k, `/\`); i >= 0 {
		k = k[i+1:]
	}
	return fn == k || strings.TrimSuffix(fn, filepath.Ext(fn)) == k
}

// looksLikeURL 判断 key 是否像一个地址（含协议，或纯 host[路径]，且不含中文等字符）
func looksLikeURL(key string) bool {
	if strings.Contains(key, "://") {
		return true
	}
	host := key
	if i := strings.IndexAny(host, "/?#"); i >= 0 {
		host = host[:i]
	}
	if host == "" || !strings.Contains(host, ".") {
		return false
	}
	for _, c := range host {
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
			c == '.' || c == '-' || c == ':' || c == '_'
		if !ok {
			return false
		}
	}
	return true
}

// hostOf 取 URL 的 host（小写、去 www.、去端口）；不像 URL 时返回空
func hostOf(u string) string {
	s := strings.TrimSpace(u)
	if s == "" {
		return ""
	}
	if !strings.Contains(s, "://") {
		s = "http://" + s
	}
	p, err := neturl.Parse(s)
	if err != nil {
		return ""
	}
	h := strings.ToLower(p.Hostname())
	if h == "" {
		return ""
	}
	return strings.TrimPrefix(h, "www.")
}

// HintNotFound 生成"未找到书源"的提示：列出可用的书源与 -source 支持的写法
func HintNotFound(list []*model.BookSource) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "可用书源（共 %d 个）:\n", len(list))
	for i, s := range list {
		file := ""
		if s.FileName != "" {
			file = s.FileName
		}
		fmt.Fprintf(&sb, "  %2d. %-24s %-34s %s\n", i+1, s.BookSourceName, s.BookSourceUrl, file)
	}
	sb.WriteString("-source 可写：序号(1)、名称、bookSourceUrl 全等、域名、" +
		"书籍详情页 URL 或文件名(如 kantianxia.json)")
	return sb.String()
}
