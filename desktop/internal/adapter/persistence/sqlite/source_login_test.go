package sqlite

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/legado/desktop/internal/domain"
)

// 登录信息的基本读写：表单值与请求头都要能原样取回。
func TestSourceLoginRepoSaveGet(t *testing.T) {
	db := newTestDB(t)
	repo := NewSourceLoginRepo(db)
	ctx := context.Background()

	// 不存在时必须是 ErrNotFound（上层据此判断「未登录」）。
	if _, err := repo.Get(ctx, "https://demo.test"); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("未保存时应返回 ErrNotFound, 得到 %v", err)
	}

	in := domain.SourceLogin{
		SourceURL: "https://demo.test",
		Form:      map[string]string{"账号": "reader", "密码": "p@ss"},
		Header:    `{"Cookie":"sid=abc"}`,
	}
	if err := repo.Save(ctx, in); err != nil {
		t.Fatalf("保存失败: %v", err)
	}

	got, err := repo.Get(ctx, "https://demo.test")
	if err != nil {
		t.Fatalf("读取失败: %v", err)
	}
	if got.Form["账号"] != "reader" || got.Form["密码"] != "p@ss" {
		t.Fatalf("表单值不一致: %#v", got.Form)
	}
	if got.Header != in.Header {
		t.Fatalf("登录头不一致: %q", got.Header)
	}
	if got.UpdatedAt.IsZero() {
		t.Fatal("更新时间未写入")
	}

	// 覆盖保存：只改 header 时表单值必须保留（两次登录是增量更新）。
	in.Header = `{"Cookie":"sid=def"}`
	if err := repo.Save(ctx, in); err != nil {
		t.Fatalf("覆盖保存失败: %v", err)
	}
	got, _ = repo.Get(ctx, "https://demo.test")
	if got.Header != `{"Cookie":"sid=def"}` || got.Form["账号"] != "reader" {
		t.Fatalf("覆盖后数据不对: %#v", got)
	}
}

// 只有表单、没有请求头（网页登录还没完成）也要能存住账号。
func TestSourceLoginRepoFormOnly(t *testing.T) {
	db := newTestDB(t)
	repo := NewSourceLoginRepo(db)
	ctx := context.Background()

	if err := repo.Save(ctx, domain.SourceLogin{
		SourceURL: "https://form.test",
		Form:      map[string]string{"user": "u1"},
		UpdatedAt: time.Unix(1700000000, 0),
	}); err != nil {
		t.Fatalf("保存失败: %v", err)
	}
	got, err := repo.Get(ctx, "https://form.test")
	if err != nil {
		t.Fatalf("读取失败: %v", err)
	}
	if !got.HasForm() || got.HasHeader() || got.IsEmpty() {
		t.Fatalf("状态判断不对: %#v", got)
	}
	if got.UpdatedAt.Unix() != 1700000000 {
		t.Fatalf("更新时间未保留: %v", got.UpdatedAt)
	}
}

// 删除要幂等：清除登录可能被点两次。
func TestSourceLoginRepoDelete(t *testing.T) {
	db := newTestDB(t)
	repo := NewSourceLoginRepo(db)
	ctx := context.Background()

	if err := repo.Save(ctx, domain.SourceLogin{
		SourceURL: "https://del.test",
		Header:    `{"Cookie":"a=1"}`,
	}); err != nil {
		t.Fatalf("保存失败: %v", err)
	}
	if err := repo.Delete(ctx, "https://del.test"); err != nil {
		t.Fatalf("删除失败: %v", err)
	}
	if err := repo.Delete(ctx, "https://del.test"); err != nil {
		t.Fatalf("重复删除应幂等, 得到 %v", err)
	}
	if _, err := repo.Get(ctx, "https://del.test"); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("删除后应查不到, 得到 %v", err)
	}

	urls, err := repo.ListSourceURLs(ctx)
	if err != nil {
		t.Fatalf("列出地址失败: %v", err)
	}
	for _, u := range urls {
		if u == "https://del.test" {
			t.Fatalf("已删除的记录仍在列表中: %#v", urls)
		}
	}
}

// 表单 JSON 损坏时不该让整个登录界面打不开：Header 仍应可用。
func TestSourceLoginRepoToleratesBrokenForm(t *testing.T) {
	db := newTestDB(t)
	repo := NewSourceLoginRepo(db)
	ctx := context.Background()

	if _, err := db.q(ctx).ExecContext(ctx,
		`INSERT INTO source_login (source_url, form_json, header, updated_at) VALUES (?, ?, ?, 0)`,
		"https://broken.test", "{not json", `{"Cookie":"k=v"}`); err != nil {
		t.Fatalf("准备数据失败: %v", err)
	}
	got, err := repo.Get(ctx, "https://broken.test")
	if err != nil {
		t.Fatalf("读取失败: %v", err)
	}
	if got.Form != nil {
		t.Fatalf("坏 JSON 应被忽略, 得到 %#v", got.Form)
	}
	if !strings.Contains(got.Header, "k=v") {
		t.Fatalf("登录头应仍然可读: %q", got.Header)
	}
}
