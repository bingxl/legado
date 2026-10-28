package util

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"regexp"
	"strings"

	"golang.org/x/text/encoding/htmlindex"
	"golang.org/x/text/transform"
)

var metaCharsetRe = regexp.MustCompile(`(?is)<meta[^>]*charset\s*=\s*['"]?\s*([a-zA-Z0-9_\-]+)`)
var contentTypeCharsetRe = regexp.MustCompile(`(?i)charset\s*=\s*['"]?\s*([a-zA-Z0-9_\-]+)`)

// NormalizeCharset 归一化编码名
func NormalizeCharset(name string) string {
	n := strings.ToLower(strings.TrimSpace(name))
	switch n {
	case "", "utf8", "utf-8", "unicode":
		return "utf-8"
	case "gb2312", "gbk", "gb18030", "x-gbk", "cp936", "windows-936":
		return "gb18030"
	case "big5", "big5-hkscs", "cp950":
		return "big5"
	case "iso-8859-1", "latin1", "latin-1":
		return "iso-8859-1"
	}
	return n
}

// DetectCharset 依次从 Content-Type 与 HTML meta 推断编码
func DetectCharset(contentType string, body []byte) string {
	if contentType != "" {
		if m := contentTypeCharsetRe.FindStringSubmatch(contentType); len(m) > 1 {
			return NormalizeCharset(m[1])
		}
	}
	if len(body) > 0 {
		head := body
		if len(head) > 4096 {
			head = head[:4096]
		}
		if m := metaCharsetRe.Find(head); len(m) > 1 {
			return NormalizeCharset(string(m[1]))
		}
	}
	return "utf-8"
}

// DecodeBytes 按编码名解码字节
func DecodeBytes(b []byte, charset string) string {
	if len(b) == 0 {
		return ""
	}
	cs := NormalizeCharset(charset)
	if cs == "utf-8" {
		return string(b)
	}
	enc, err := htmlindex.Get(cs)
	if err != nil || enc == nil {
		return string(b)
	}
	r := transform.NewReader(bytes.NewReader(b), enc.NewDecoder())
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(r); err != nil {
		return string(b)
	}
	return buf.String()
}

// EncodeBytes 按编码名把字符串编码为字节（未知编码回退 UTF-8）
//
// 与 DecodeBytes 对称：URL 选项里的 charset=gbk 要求把关键字按 GBK 字节发出去，
// 否则 GBK 站点会把 UTF-8 字节当 GBK 解，得到乱码且搜不到结果。
func EncodeBytes(s string, charset string) []byte {
	cs := NormalizeCharset(charset)
	if cs == "utf-8" {
		return []byte(s)
	}
	enc, err := htmlindex.Get(cs)
	if err != nil || enc == nil {
		return []byte(s)
	}
	b, _, err := transform.Bytes(enc.NewEncoder(), []byte(s))
	if err != nil {
		return []byte(s)
	}
	return b
}

// Base64Encode / Base64Decode
func Base64Encode(s string, flags int) string {
	switch flags {
	case 0:
		return base64.StdEncoding.EncodeToString([]byte(s))
	case 1:
		return base64.URLEncoding.EncodeToString([]byte(s))
	default:
		return base64.StdEncoding.EncodeToString([]byte(s))
	}
}

func Base64Decode(s string, flags int) string {
	s = strings.TrimSpace(s)
	var data []byte
	var err error
	switch flags {
	case 1:
		data, err = base64.URLEncoding.DecodeString(s)
	default:
		data, err = base64.StdEncoding.DecodeString(s)
		if err != nil {
			data, err = base64.RawStdEncoding.DecodeString(s)
		}
	}
	if err != nil {
		return ""
	}
	return string(data)
}

func Base64DecodeBytes(s string) []byte {
	s = strings.TrimSpace(s)
	if d, err := base64.StdEncoding.DecodeString(s); err == nil {
		return d
	}
	if d, err := base64.RawStdEncoding.DecodeString(s); err == nil {
		return d
	}
	if d, err := base64.URLEncoding.DecodeString(s); err == nil {
		return d
	}
	return nil
}

func HexEncode(s string) string { return hex.EncodeToString([]byte(s)) }

func HexDecode(s string) []byte {
	b, _ := hex.DecodeString(strings.TrimSpace(s))
	return b
}

func HexDecodeString(s string) string { return string(HexDecode(s)) }
