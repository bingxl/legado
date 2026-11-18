# client —— Flutter UI

> **一条硬规则**：Dart 只做渲染与平台 API 调用。业务逻辑（含书源规则、缓存、分段、排序、持久化）
> 一律在 Go `core/` 里。判定三问见 `docs/MODULE-PLAN.md` §1.1。

## 本地运行

两种方式，任选其一。

**A. 先起 core，再起 UI（推荐，能看 core 日志）**

```powershell
cd hosts
go run ./cli serve -port 8580
# 另开一个终端
cd client
flutter run -d windows
```

**B. 让 UI 自己拉起 core**

把编译好的 core 放到应用同目录，命名为 `legado-core.exe`：

```powershell
pwsh -File scripts/build.ps1 -Target core
```

`LegadoClient.connect()` 的顺序是：`--dart-define=LEGADO_ENDPOINT` → 环境变量 `LEGADO_ENDPOINT`
→ `127.0.0.1:8580` 探活 → 拉起 `legado-core serve -port 0` 并解析 stdout 的 `listening http://…`。

> core 可执行文件**必须**叫 `legado-core`：与 Flutter 的 `legado.exe` 同名会互相覆盖。

## 目录

```
lib/
├── main.dart                  # 入口：连 bridge → 拉配置 → HomeShell；路由在此接线
├── core/
│   ├── bridge/                # 唯一与 Go 通信的层（call/callList、错误码）
│   ├── router/routes.dart     # 冻结：路由常量 + 标题 + 占位页
│   └── theme/app_theme.dart   # 冻结：主题（取原版 colors.xml）
└── features/
    ├── shelf/                 # 书架（分组、网格/列表）
    ├── shell/                 # 主框架（4 tab + 桌面快捷键）
    ├── explore/ search/ book/ # 发现、搜索、详情
    ├── reader/                # 阅读器（分页、翻页、菜单、目录、进度）
    ├── source/                # 书源管理/编辑/调试
    ├── rss/                   # RSS 订阅
    ├── settings/              # 设置中心（Schema 驱动）
    ├── me/                    # 「我的」tab（概览 + 入口）
    └── tools/                 # 缓存管理、书签、阅读记录
```

`features/<域>/` 是目录所有权边界：并行开发时一个模块只改自己的目录，
**不碰** `core/`、`main.dart`、`routes.dart`、`pubspec.yaml`。

### 设置中心是「Schema 驱动」的

设置项的标题、控件类型、默认值、合法区间、下拉选项全部由 core 的
`Settings.Schema` 下发（见 `core/modules/settings/schema.go`），Dart 侧只负责按
`kind` 画控件，**不要**在页面里硬编码某个设置项。加一项设置的流程是：

1. 在 Go 侧给它接上消费者（没有消费者的开关不许进 Schema）；
2. 加进 `DefaultSchema()`，需要落库就在 `port` 里加键常量；
3. 页面自动出现，前端零改动。

阅读器与设置共享同一份数据：`features/reader/reader_prefs.dart` 是唯一的翻译层，
菜单里调字号/背景会写回 core，设置页改完阅读器立刻生效。别再引入第二份本地存储
（旧的 `ReaderStyleStore` 已因此删除）。

## 检查

```powershell
flutter analyze
flutter test
# 方法名交叉校验：Dart 里出现的 'Domain.Verb' 是否都真的在 core 注册过
pwsh -File ../scripts/check-methods.ps1
```

分页、HTML 去标签、搜索结果合并这些纯函数都有单测，改动后先跑 `flutter test`。

`check-methods.ps1` 值得单独说明：控制面方法名是字符串字面量，Go 和 Dart 都不会
在编译期发现拼错，只会在运行期表现为「按钮点了没反应」。这个脚本把两边对一遍。

## 允许与禁止

| 允许 | 禁止（CI 会 grep） |
|---|---|
| 排版测量与分页（`TextPainter`） | `sqflite` / `drift`（数据库只能在 Go） |
| 手势、动画、滚动位置 | `dio` / 直接调业务 HTTP（一律走 `LegadoClient`） |
| 图片解码与 `ImageCache` | `dart:io` 直接读写书库文件 |
| 系统 TTS / 音频播放控制 | 用 `RegExp` 解析书源规则、HTML、RSS |
| 文件选择、权限、剪贴板 | `shared_preferences` 存业务数据（只能存窗口位置等 UI 偏好） |

例外写在 `analysis_options.yaml` 注释里，新增例外需说明理由。
