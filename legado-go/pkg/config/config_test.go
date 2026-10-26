package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDefault(t *testing.T) {
	c := Default()
	if c.SourceDir != "./sources" || c.CookieFile != "cookies.json" || c.CacheFile != "cache.json" {
		t.Fatalf("默认值不对: %+v", c)
	}
	if c.HTTPTimeout != 30 || c.JSTimeout != 30 {
		t.Fatalf("默认超时不对: %+v", c)
	}
	if c.Download.OutDir != "./out" || c.Download.Workers != 4 {
		t.Fatalf("默认下载参数不对: %+v", c.Download)
	}
}

// 配置文件里没写的项应保留默认值，而不是变成零值
func TestLoadKeepsDefaults(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(p, []byte(`{"sourceDir":"../sources","jsTimeout":5}`), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if c.SourceDir != "../sources" {
		t.Fatalf("sourceDir 未生效: %q", c.SourceDir)
	}
	if c.JSTimeout != 5 {
		t.Fatalf("jsTimeout 未生效: %d", c.JSTimeout)
	}
	if c.HTTPTimeout != 30 {
		t.Fatalf("未写的 httpTimeout 应保留默认 30，得到 %d", c.HTTPTimeout)
	}
	if c.Download.Workers != 4 {
		t.Fatalf("未写的 download.workers 应保留默认 4，得到 %d", c.Download.Workers)
	}
	if c.Path() != p {
		t.Fatalf("Path 不对: %q", c.Path())
	}
}

func TestLoadNotExist(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "nope.json")); !os.IsNotExist(err) {
		t.Fatalf("期望 os.ErrNotExist，得到 %v", err)
	}
}

func TestLoadSyntaxError(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.json")
	_ = os.WriteFile(p, []byte(`{"sourceDir": }`), 0o644)
	if _, err := Load(p); err == nil {
		t.Fatal("语法错误应报错")
	}
}

func TestUnknownFields(t *testing.T) {
	c, err := Unmarshal([]byte(`{
		"sourceDir": "x",
		"cookiefile": "a.json",
		"unknownKey": 1,
		"download": {"outdir": "y", "workers": 2}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	got := c.UnknownFields()
	want := map[string]bool{"cookiefile": true, "unknownKey": true, "download.outdir": true}
	if len(got) != len(want) {
		t.Fatalf("未知字段数量错误: %v", got)
	}
	for _, f := range got {
		if !want[f] {
			t.Fatalf("多报未知字段: %s（全部 %v）", f, got)
		}
	}
	// 大小写正确的字段不应被判为未知
	if _, err := Unmarshal([]byte(`{"sourceDir":"x","cookieFile":"a","download":{"outDir":"y"}}`)); err != nil {
		t.Fatal(err)
	}
}

func TestSuggestField(t *testing.T) {
	cases := map[string]string{
		"cookiefile":      "cookieFile",
		"cachefile":       "cacheFile",
		"source-dir":      "sourceDir",
		"js_timeout":      "jsTimeout",
		"useragent":       "userAgent",
		"download.worker": "download.workers",
		"totallyWrong":    "",
	}
	for in, want := range cases {
		if got := SuggestField(in); got != want {
			t.Fatalf("SuggestField(%q) = %q, 期望 %q", in, got, want)
		}
	}
}

func TestValidateOK(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "sources")
	if err := os.Mkdir(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	c := Default()
	c.SourceDir = sub
	c.CookieFile = filepath.Join(dir, "c.json")
	r := c.Validate(nil)
	if !r.OK() {
		t.Fatalf("不应有错误: %v", r.Issues)
	}
}

func TestValidateErrors(t *testing.T) {
	c := Default()
	c.SourceDir = "./definitely-not-exists-xyz"
	c.SourceFile = "./also-not-exists.json"
	c.HTTPTimeout = -1
	c.JSTimeout = 9999
	c.UserAgent = "a\nb"
	c.Download.Format = "pdf"
	c.Download.Workers = -2
	c.Download.Max = -1
	c.Download.Start = -1
	r := c.Validate(nil)
	if r.OK() {
		t.Fatal("应报错误")
	}
	fields := map[string]Level{}
	for _, i := range r.Issues {
		if old, ok := fields[i.Field]; !ok || i.Level > old {
			fields[i.Field] = i.Level
		}
	}
	for _, f := range []string{"sourceDir", "sourceFile", "httpTimeout", "userAgent",
		"download.format", "download.workers", "download.max", "download.start"} {
		if fields[f] != LevelError {
			t.Fatalf("字段 %s 应为错误，实际 %v（全部: %v）", f, fields[f], r.Issues)
		}
	}
	if fields["jsTimeout"] != LevelWarn {
		t.Fatalf("jsTimeout 9999 应为警告，实际 %v", fields["jsTimeout"])
	}
}

func TestValidateBothSourceSet(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "sources")
	_ = os.Mkdir(sub, 0o755)
	f := filepath.Join(dir, "a.json")
	_ = os.WriteFile(f, []byte(`[]`), 0o644)

	c := Default()
	c.SourceDir = sub
	c.SourceFile = f
	r := c.Validate(nil)
	if !r.OK() {
		t.Fatalf("两者都设不应算错误: %v", r.Issues)
	}
	found := false
	for _, i := range r.Issues {
		if i.Field == "sourceFile" && strings.Contains(i.Msg, "优先") {
			found = true
		}
	}
	if !found {
		t.Fatalf("应提示 sourceFile 优先: %v", r.Issues)
	}
}

func TestNormalize(t *testing.T) {
	c := &FileConfig{SourceDir: "  ./s  ", Download: Download{Workers: 999, Format: "TXT"}}
	c.Normalize()
	if c.SourceDir != "./s" {
		t.Fatalf("sourceDir 未 trim: %q", c.SourceDir)
	}
	if c.HTTPTimeout != 30 || c.JSTimeout != 30 {
		t.Fatalf("超时应补默认: %+v", c)
	}
	if c.Download.Workers != 64 {
		t.Fatalf("workers 应钳到 64，得到 %d", c.Download.Workers)
	}
	if c.Download.OutDir != "./out" {
		t.Fatalf("outDir 应补默认，得到 %q", c.Download.OutDir)
	}
	if c.Download.Format != "txt" {
		t.Fatalf("format 应转小写，得到 %q", c.Download.Format)
	}
}

func TestSaveNoOverwrite(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "sub", "config.json")
	c := Default()
	if err := c.Save(p, false); err != nil {
		t.Fatalf("首次保存失败: %v", err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("文件未生成: %v", err)
	}
	if err := c.Save(p, false); err == nil {
		t.Fatal("已存在时应报错")
	}
	if err := c.Save(p, true); err != nil {
		t.Fatalf("force 应能覆盖: %v", err)
	}
}

// 生成的 JSON 必须能被自己读回（字段名一致）
func TestEncodeRoundTrip(t *testing.T) {
	c := Default()
	c.Source = "yumanhua"
	c.Download.Format = "images"
	b, err := c.Encode()
	if err != nil {
		t.Fatal(err)
	}
	back, err := Unmarshal(b)
	if err != nil {
		t.Fatal(err)
	}
	if len(back.UnknownFields()) != 0 {
		t.Fatalf("自己生成的字段不应未知: %v", back.UnknownFields())
	}
	if back.Source != "yumanhua" || back.Download.Format != "images" {
		t.Fatalf("往返丢字段: %+v", back)
	}
}
