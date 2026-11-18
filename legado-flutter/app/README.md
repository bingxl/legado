# app —— Flutter 应用

> **一条硬规则**：Dart UI 只做渲染与平台 API 调用。业务逻辑（书源规则、缓存、
> 分段、排序、持久化）一律在 `../packages/legado_core` 里。
> 内核是纯 Dart，与 CLI 共用同一份实现。

## 本地运行

```powershell
# 依赖（本机代理连不上 pub.dev，需要镜像）
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
cd legado-flutter
flutter pub get

cd app
flutter run -d windows
```

内核跑在同一进程里，没有子进程、没有端口、没有 TCP 回环。
数据目录默认是 App 私有目录；想用别的目录（例如和 CLI 共用一份数据）：

```powershell
flutter run -d windows --dart-define=LEGADO_HOME=C:\data\legado
```

## 目录

```
lib/
├── main.dart                  # 入口：连内核 → HomeShell；路由在此接线
├── core/
│   ├── bridge/                # 唯一与内核通信的层（call/callList、错误码）
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

设置项的标题、控件类型、默认值、合法区间、下拉选项全部由内核的
`Settings.Schema` 下发，Dart 侧只负责按 `kind` 画控件，**不要**在页面里硬编码某个设置项。
加一项设置的流程是：

1. 在内核里给它接上消费者（没有消费者的开关不许进 Schema）；
2. 加进内核的 `defaultSchema()`；
3. 页面自动出现，前端零改动。

阅读器与设置共享同一份数据：`features/reader/reader_prefs.dart` 是唯一的翻译层，
菜单里调字号/背景会写回内核，设置页改完阅读器立刻生效。别再引入第二份本地存储。

## 检查

```powershell
flutter analyze
flutter test
# 方法名交叉校验：Dart 里出现的 'Domain.Verb' 是否都真的在内核注册过
pwsh -File ../../scripts/check-methods.ps1
```

分页、HTML 去标签、搜索结果合并这些纯函数都有单测，改动后先跑 `flutter test`。

## 允许与禁止

| 允许 | 禁止 |
|---|---|
| 排版测量与分页（`TextPainter`） | `sqflite` / `drift`（数据库只能在内核） |
| 手势、动画、滚动位置 | `dio` / 直接调业务 HTTP（一律走 `LegadoClient`） |
| 图片解码与 `ImageCache` | 用 `RegExp` 解析书源规则、HTML、RSS |
| 系统 TTS / 音频播放控制 | `shared_preferences` 存业务数据（只能存窗口位置等 UI 偏好） |

例外写在 `analysis_options.yaml` 注释里，新增例外需说明理由。
