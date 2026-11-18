# archive —— 已退役实现的设计文档

这些文档描述的是 **Go 内核 + Wails 桌面端** 那一版实现（`legado-go/` `core/` `hosts/`
`desktop/`），这些目录已在 Flutter 全量迁移中从本分支删除。文件保留下来是因为其中
的调研与踩坑结论仍然有效，重写 Dart 内核时会反复用到：

| 文档 | 现在还有什么用 |
| --- | --- |
| `desktop-ARCHITECTURE-V2.md` | 模块划分、方法注册表、缓存/阅读器/音频的行为约定 |
| `desktop-TECH-SELECTION.md` | EPUB/漫画/PDF 的 Go 生态调研，换成 Dart 生态时是对照表 |
| `desktop-MODULE-PLAN.md` | 域边界划分理由（哪些逻辑属于内核、哪些属于 UI） |
| `desktop-CF-BYPASS-SURVEY.md` | Cloudflare 挑战的检测与放行方式，与语言无关 |
| `desktop-COOKIE-MULTIPLATFORM.md` | Cookie 容器与 HttpOnly 读取（WebView2 CDP）的结论 |
| `desktop-WAILS-FORK-COOKIE.md` | Wails 侧改动的来龙去脉，仅作历史 |

看这些文档时记住两点：

1. 里面出现的 `go build` / `task` / `legado-core.exe` / `gomobile` 命令**全部作废**，
   现在的构建流程只有 `flutter build` 与 `dart run`。
2. 凡是写「Go 侧」「core/」的地方，对应到现在的
   `legado-flutter/packages/legado_core/lib/src/`。

当前的架构与迁移计划见 `../flutter-全量迁移规划.md`。
