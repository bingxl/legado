// Package registry 汇总所有模块。**这是唯一需要改动的装配点**，
// 新增模块时在这里加一行（避免多个并行分支改同一个文件导致冲突时，
// 优先让模块自己 init 注册；当前模块数量少，显式列表更好读）。
package registry

import (
	"github.com/legado/core/boot"
	"github.com/legado/core/kernel"
	"github.com/legado/core/modules/bookmark"
	"github.com/legado/core/modules/legacy"
	"github.com/legado/core/modules/rss"
	"github.com/legado/core/modules/settings"
	"github.com/legado/core/modules/tts"
)

// Modules 返回全量模块（拓扑顺序由 kernel.Boot 决定）。
func Modules(biz *boot.App, version string) []kernel.Module {
	mods := legacy.Modules(biz, version)
	mods = append(mods,
		rss.New(biz.DB),
		tts.New(biz.DB),
		bookmark.New(biz.DB),
		settings.New(biz.Settings),
	)
	return mods
}
