# Flutter 全量迁移规划（纯 Dart 内核）

> 目标：用 Flutter 全量实现原版 legado（`app/`，119 666 行 Kotlin / 813 文件）的全部功能，
> 非 UI 逻辑收敛为**纯 Dart 包**，既能被 Flutter 进程内调用，也能用 `dart run` 当 CLI 跑。
> 计划日期：2026-11-18 ／ 分支：`flutter`

## 决策记录（2026-11-18 已定）

| 决策点 | 结论 | 影响 |
| --- | --- | --- |
| 书源 JS | **先纯 Dart 子集，规则层留 `JsEngine` 接口可换 QuickJS** | M2 内先做子集；实测覆盖率 <90% 再换 FFI，不动规则层 |
| Go 目录 | **全删**：`legado-go/` `core/` `hosts/` `dist/` `desktop/` | 分支上不再有任何 Go 代码；desktop（Wails）退场，历史在其他分支可取回 |
| 现有 15.5k Dart UI | **整体迁入复用**，只换 transport | `client/` → `legado-flutter/app/`，19 页 + 157 用例保留 |
| 平台范围 | **Android + Windows 双端** | 平台能力两条线都要做，M7 工作量 +30% |

`app/`、`cli/`、`modules/` 与根 Gradle 文件**保留不动**（只读参考；`cli/` 复用 `app` 的规则引擎源码，
是取「同一书源期望输出」最方便的工具）。`legado-flutter/` 独立于 Gradle 工程，不参与 Kotlin 构建。

---

## 一、现状盘点（真实统计，非估算）

| 目录 | 语言 | 行数 | 文件 | 去留 |
| --- | --- | --- | --- | --- |
| `app/` | Kotlin | 119 666 | 813 | **保留**，只读参考（功能与语义的唯一真源） |
| `cli/` | Kotlin | 5 249 | 65 | **保留**，只读参考（取同一书源的期望输出） |
| `legado-go/` | Go | 19 631 | 77 | **删除**（规则引擎 Go 版） |
| `core/` | Go | 37 293 | 158 | **删除**（业务层，13 个文件直接依赖 legado-go） |
| `hosts/` | Go | 789 | 6 | **删除**（CLI/HTTP/FFI 三宿主） |
| `desktop/` | Go+Vue | 4 458 + 15 201 | 35+31 | **删除**（Wails 桌面端，import `core`，Go 侧退场后无意义） |
| `client/` | Dart | 15 512 | 76 | **迁入** `legado-flutter/app/` |

现有 Flutter 资产：19 个页面、22 个测试文件、157 个用例全绿，控制面 **156 个方法**（17 个域）。

原版 UI 规模：`book` 160 文件、`widget` 71、`rss` 30、`association` 26、`main` 22、`config` 12，
Activity/Fragment/Dialog 共 **141 个**。

**结论：已完成约 15%~20%。** 主要缺口不是页面数量，而是三块硬骨头：
书源规则引擎、图书格式解析（epub/umd/漫画/PDF）、平台能力（后台服务/通知/朗读）。

---

## 二、目标目录结构

```
legado-flutter/
├── pubspec.yaml                     # Dart pub workspace 根（workspace: packages/*, app）
├── analysis_options.yaml            # 统一 lint（纯 Dart 包与 Flutter 包共用）
├── packages/
│   ├── legado_core/                 # ★ 纯 Dart，禁止 import flutter / dart:ui
│   │   ├── lib/legado_core.dart     # 唯一门面：LegadoCore
│   │   ├── lib/src/domain/          # 实体与值对象（Book/Chapter/BookSource/ReadConfig…）
│   │   ├── lib/src/rules/           # 书源规则引擎：CSS / XPath / JSONPath / 正则 / URL / 拼接
│   │   ├── lib/src/js/              # JS 解释器（JsEngine 接口 + 默认纯 Dart 实现）
│   │   ├── lib/src/net/             # HTTP、Cookie、Cloudflare、并发限流、编码探测
│   │   ├── lib/src/store/           # sqlite3 DAO + schema 迁移
│   │   ├── lib/src/service/         # 应用服务（书架/阅读/书源/缓存/RSS/同步…）
│   │   └── lib/src/util/            # 纯函数工具（HTML 处理、文本规范化、日期）
│   └── legado_cli/                  # 纯 Dart，CLI 宿主
│       ├── bin/legado.dart          # info / schema / methods / call / serve
│       └── native/                  # CLI 用的 sqlite3 动态库（Windows）
└── app/                             # Flutter 应用
    ├── lib/                         # 现有 client/lib 全量迁入
    ├── test/                        # 现有 157 用例随迁
    ├── android/ windows/ ios/ …     # 平台宿主
    └── build/                       # 编译产物（gitignore）
```

**关键约束**：`legado_core` 的 `pubspec.yaml` 里不允许出现 `flutter` 依赖。
这条约束用一个测试守住：扫描 `packages/legado_core/lib` 是否出现 `package:flutter` 或 `dart:ui`。

---

## 三、双端运行形态

### 3.1 同一份契约

沿用现有的方法名契约（156 个），UI 与 CLI 走同一个入口：

```dart
// UI 侧（进程内，无序列化开销）
final books = await LegadoCore.instance.call('Shelf.ListBooks', [0]);

// CLI 侧（信封序列化，便于脚本与回归）
// dart run legado_cli:legado call Shelf.ListBooks '[0]'
// → {"id":1,"ok":true,"data":[...]}
```

**为什么保留方法名字符串契约**：现有 15.5k Dart UI 只依赖 `LegadoClient.call` 一个函数，
换 transport 后 UI 几乎不用改；同时 CLI 天然获得全部功能（`legado methods` 就是功能清单），
并行开发时它就是各模块之间的冻结接口。

### 3.2 CLI 命令面

| 命令 | 作用 |
| --- | --- |
| `legado info` | 版本、数据目录、平台 |
| `legado schema` | 设置项 Schema（JSON） |
| `legado methods [Domain]` | 方法表（含参数签名） |
| `legado call <Method> [argsJSON]` | 调用任意方法 |
| `legado serve -port` | HTTP + SSE 数据面（给浏览器调试/远程用） |
| 域命令 | 如 `legado shelf list`、`legado source import x.json`，由模块自注册 |

`dart compile exe` 可产出单文件二进制，供不想装 Dart 的场景使用。

---

## 四、功能全景与覆盖度

| 域 | 原版对应 | 现有方法 | 现有 UI | 缺口 |
| --- | --- | --- | --- | --- |
| 书架 | `ui/book`（书架部分） | Shelf 11 | `shelf_page` | 分组增删改、多选批量、本地/网络导入、封面规则、书籍信息编辑、换源 |
| 书源 | `ui/config`、`BookSourceEdit/Debug` | Source 38 · SourceDebug 3 · SourceLogin 7 | 列表/编辑/调试 3 页 | 分组管理、导入导出、规则校验、jsLib、登录流程细化 |
| 规则引擎 | `model/analyzeRule`、`lib/rhino` | （藏在 Go 里） | — | **CSS/XPath/JSONPath/正则/JS 全部要在 Dart 重写** |
| 发现 | `ExploreFragment`、`ExploreShow` | Source 内 | `explore_page` | 分类矩阵、多源并行、翻页增量 |
| 搜索 | `ui/main` 搜索 | Source 内 | `search_page` | 书籍/章节双模式、并发控制、结果合并排序 |
| 阅读 | `ui/book/read` | Reader 5 | 阅读器全套（分页/翻页/菜单/目录） | epub/umd/漫画/PDF、双页与分屏、朗读、取词、正文编辑、自动翻页、背景图 |
| 缓存 | `CacheActivity` | Cache 10 | `cache_page` | 漫画缓存、音频缓存、批量范围下载 |
| 书签/记录 | `BookmarkFragment`、`AllBookmark` | Bookmark 5 · Record 4 | 2 页 | 书签备注同步、统计维度 |
| RSS | `ui/rss`（30 文件） | Rss 10 | 4 页 | 规则调试、分组、朗读、全文抓取 |
| 设置 | `ui/config`（12）+ pref XML | Settings 5 | 3 页（Schema 驱动） | 40+ 阅读项、字体、主题、点击区域、翻页模式细化 |
| 词典 | `ui/dict` | Dict 13 | 无 | 取词、规则编辑、在线翻译 |
| TTS/听书 | `HttpTts`、`service` | Tts 1 · Audio 7 | 朗读面板（调系统 TTS） | 规则 TTS、听书服务、通知栏控制、跨章续读 |
| AI | `ui/book/read` AI 面板 | Ai 15 | 无 | 问答、生成本地向量、书内检索 |
| WebDAV/备份 | `BackupConfig` | WebDAV 11 | 无 | 备份/还原、定时上传、书籍远程同步 |
| 替换净化 | `ui/replace` | ReplaceRule 7 | 无 | 规则编辑、生效预览、导入导出 |
| 本地文件 | `FileManage`、`association` | Library 2 | 无 | 文件管理、格式识别、文件关联 |
| 平台 | `service` 10 · `receiver` 4 | System 2 | 无 | 后台任务、通知、听书前台服务、Web 服务、深链 |

---

## 五、技术选型与三个高危点

### 依赖（全部纯 Dart，CLI 可用）

| 用途 | 选型 | 备注 |
| --- | --- | --- |
| 数据库 | `sqlite3`（FFI） | Flutter 侧配 `sqlite3_flutter_libs`；CLI 侧需 `sqlite3.dll`，用脚本拉取 |
| HTML | `package:html` + `csslib` | 接近 jsoup 的 HTML5 解析，`querySelector` 可直接支撑 CSS 规则 |
| XML/RSS | `package:xml` | RSS/OPDS/epub container |
| 压缩 | `package:archive` | zip/epub；rar/7z 需另议 |
| 编码 | `package:gbk_codec` + 自研探测 | 原版用 juniversalchardet，Dart 无对等物 |
| HTTP | `package:http` + 自建 Cookie 容器 | 需要连接级 Cookie、代理、重试 |
| 参数/日志 | `package:args`、`package:logging` | CLI |

Flutter 侧额外：`sqlite3_flutter_libs`、`flutter_tts`、`file_picker`、`path_provider`、
`shared_preferences`（仅窗口位置等 UI 偏好）。

### 高危点 1：书源 JS（最大不确定性）

原版用 Rhino，`legado-go/pkg/js` 自研了 2924 行子集。Dart 的三条路：

| 方案 | 覆盖度 | CLI 可用 | 构建复杂度 | 判定 |
| --- | --- | --- | --- | --- |
| 纯 Dart 子集解释器 | 中（按语法特性渐进） | ✅ 天然 | 低 | **推荐** |
| `flutter_js`（QuickJS/JSC） | 高 | ❌ 依赖 Flutter plugin | 低 | 不能用于 CLI |
| Dart FFI + 自编 QuickJS | 高 | ✅ 需带 dll/so | 高（每平台编） | 备选 |

**推荐**：先做纯 Dart 子集，规则层留 `JsEngine` 抽象接口；用真实书源建立 golden 语料，
统计「脚本执行成功率」。若低于 90%，再换 FFI QuickJS 而不动规则层。

### 高危点 2：XPath over HTML

`package:xml` 的 XPath 只认合法 XML，脏 HTML 会解析失败。而书源里 XPath 规则占比很高。
**方案**：用 `package:html` 建 DOM，自研 XPath 子集（`//`、`/`、`@attr`、`text()`、
位置谓词、`contains/starts-with/normalize-space` 等常用函数），行为对齐 jsoup+JAXP。
这条路径 legado-go 已验证可行（`pkg/rule` 3277 行），Dart 侧按同一算法翻译。

### 高危点 3：图书格式

| 格式 | 方案 | 风险 |
| --- | --- | --- |
| txt | 自研（编码探测 + 目录正则 + 分章） | 低（Go 版已有实现可翻） |
| epub | `package:archive` + `package:xml` 解析 container/opf/ncx | 中 |
| umd | 自研二进制解析 | 中（有公开格式文档） |
| 漫画 zip/cbz | `package:archive` | 低 |
| 漫画 rar/7z | 需 native 库 | 高 → 先只支持 zip，rar 后置 |
| pdf | Flutter 用 `pdfx`；CLI 不渲染只取页数 | 中 |
| 音频 | 平台播放器 | 中 |

### 兼容性基线

- **书源 JSON 100% 兼容**（`ruleSearch/ruleBookInfo/ruleToc/ruleContent/ruleExplore` + `jsLib`）
- 备份文件（`backup.zip`、`bookSource.json`、阅读配置）可导入还原
- 旧版本（桌面 Go 版）写过的 `app_settings` 键值可被识别

---

## 六、里程碑

| # | 里程碑 | 内容 | 验收 |
| --- | --- | --- | --- |
| M0 | 骨架与搬迁 | `legado-flutter/` workspace、`legado_core` 空壳 + `LegadoCore.call`、`legado_cli` 可跑 `methods`、`client/` 迁入 `app/` | `dart run legado_cli:legado methods` 有输出；`flutter test` 157 例仍全绿 |
| M1 | 数据层 | sqlite3 schema（从 Go 版 SQL 移植）+ DAO + 迁移框架 | `dart test` 覆盖 book/chapter/source/settings/cache 的 CRUD |
| M2 | 规则引擎 | CSS/XPath/JSONPath/正则/URL 拼接 + JS 子集 + 书源全链路 | 20 个真实书源：搜索→详情→目录→正文 全部成功 |
| M3 | 基础域 | 书架、书籍、章节、正文、缓存、书签、记录、设置 | CLI 端到端：导入 txt → 列表 → 读章 → 写进度 |
| M4 | 网络与登录 | Cookie、Cloudflare、代理、并发限流、登录脚本 | 需要登录的书源可正常取正文 |
| M5 | 增强域 | RSS、替换净化、TTS、词典、AI、WebDAV、备份 | 各域 CLI 命令可用 |
| M6 | UI 全量 | 141 个界面对齐（按域并行） | 每个域有 widget 测试 + 与 `app/` 逐屏对照 |
| M7 | 平台能力 | Android 后台服务/通知/朗读、Windows 窗口/快捷键/文件关联 | 真机与桌面各跑通主流程 |
| M8 | 发布验收 | 打包、兼容性回归、性能 | 100 书源批量巡检通过率 |

**顺序理由**：M1/M2 是所有域的地基，不能并行铺 UI；M3 之后 UI 与域服务可两条线并行。

### M0 具体变更（开工第一件事）

```text
删除（git rm -r）      legado-go/  core/  hosts/  desktop/  dist/
迁移（git mv）         client/  →  legado-flutter/app/
新增                   legado-flutter/pubspec.yaml            # workspace 根
                       legado-flutter/packages/legado_core/     # 纯 Dart 空壳 + LegadoCore.call
                       legado-flutter/packages/legado_cli/      # bin/legado.dart
                                                               # native/ + 拉 sqlite3.dll 的脚本
改写                   scripts/build.ps1      # core + flutter → 只 flutter；去掉 icacls/AAR 逻辑
                       scripts/check-methods.ps1  # 对比对象从 legado-core methods 改为 dart run methods
                       .gitignore          # 加 legado-flutter/**/build、native/*.dll、*.aar
```

M0 完成标志（三条都必须真跑）：

1. `dart run legado_cli:legado methods` 打印方法表（M0 阶段可以只有 `System.*` 与占位域）
2. `cd legado-flutter/app && flutter test` → 157 例全绿（迁入未破坏 UI）
3. `flutter build apk --debug` 与 `flutter build windows` 各成功一次（无 Go、无 NDK、无 AAR）

第 3 条是这次重组的核心验证：**同一套代码，两个平台，一条命令**。


---

## 七、并行分工与冻结契约

| 角色 | 目录所有权 | 冻结文件（只读） |
| --- | --- | --- |
| 内核 | `packages/legado_core/lib/src/{domain,store,kernel}` | `lib/legado_core.dart` 导出面 |
| 规则 | `packages/legado_core/lib/src/{rules,js}` | `rules/rule.dart` 接口 |
| 各功能域 | `packages/legado_core/lib/src/service/<域>/` | 方法名与参数签名表 |
| UI 各域 | `app/lib/features/<域>/` | `main.dart`、`routes.dart`、`app_theme.dart` |
| CLI | `packages/legado_cli/` | — |

**唯一接口契约**：方法名 + 位置参数。任何模块新增/修改方法，先改契约表再改实现，
`legado methods` 导出的表就是验收依据。

---

## 八、M0 执行记录（2026-11-19 完成）

### 实际做了什么

```
删除   legado-go/ core/ hosts/ desktop/ dist/        （600 个文件从 git 移除）
迁移   client/ → legado-flutter/app/                 （123 个文件 git mv，保留历史）
新增   legado-flutter/{pubspec.yaml,analysis_options.yaml,README.md}
       legado-flutter/packages/legado_core/          纯 Dart 内核（kernel + System 模块）
       legado-flutter/packages/legado_cli/           CLI 宿主（info/methods/call/serve）
       docs/archive/                                 桌面端 6 份设计文档归档
改写   app/lib/core/bridge/legado_client.dart        HTTP/子进程 → 进程内 LegadoCore.call
       scripts/build.ps1、scripts/check-methods.ps1  不再依赖 Go
```

### 验收结果（全部真跑）

| 项 | 结果 |
| --- | --- |
| `dart test`（内核） | 13 例通过（注册表、信封、错误码、拓扑装配、纯 Dart 约束） |
| `dart run bin/legado.dart methods` | 3 个方法，`System.Info` 报 `host: cli` |
| `flutter test`（应用） | **157 例全绿**（从 client 迁入后零改动） |
| `flutter analyze` | No issues（内核、CLI、应用三处） |
| `flutter build windows --debug` | `legado.exe` 1.2MB，完整性级别已提为 Medium |
| `flutter build apk --debug` | `app-debug.apk` 143MB，4 个 so，**无 libgojni** |
| `dart compile exe` | `dist/legado.exe` 6.2MB 单文件，可独立运行 |
| `check-methods.ps1` | 内核 3 / Dart 引用 2，全部命中 |

体积与复杂度对比：Android 构建从「Go + NDK + gomobile + AAR + Gradle」五段式降为
`flutter build apk` 一条命令；不再需要 `icacls` 修 AAR，不再有 `legado-core.exe` 29.6MB。

### 构建环境踩坑（换机器必看）

| 现象 | 根因 | 处置 |
| --- | --- | --- |
| `Proxy failed to establish tunnel (502)` | 内网代理连不上 pub.dev | `PUB_HOSTED_URL=https://pub.flutter-io.cn` |
| `Unsupported class file major version 69` | Flutter 用 Android Studio 自带 JBR（Java 25），Gradle 8.14 只支持到 21 | `android/gradle.properties` 钉 `org.gradle.java.home` 到 JDK 21 |
| `Failed to install ndk;28.2...` | `ndkVersion = flutter.ndkVersion` 指向未安装版本；本机 `ndk/27`、`ndk/28` 是下载中断的空壳目录 | app 显式 `ndkVersion = "29.0.14206865"`（本机唯一完整） |
| `CMake '3.22.1' was not found` | **Flutter 3.38 对每个工程无条件调用 `forceNdkDownload()`**，把 `externalNativeBuild.cmake` 指向空 CMakeLists，逼 AGP 装 NDK，于是纯 Dart 工程也真的需要 CMake；本机 `cmake/3.22.1` 同样是空壳 | `pip install cmake==3.22.1` 的 wheel 解包进 `$ANDROID_HOME/cmake/3.22.1` + 写 `source.properties` |
| `Could not find io.flutter:arm64_v8a_debug` | tuna 镜像没有 `download.flutter.io` 分支（404） | `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` |
| Gradle 里多出 `:jni` 工程要 NDK | `path_provider_android` 2.3.0+ 改用 jni 直连 | `dependency_overrides: path_provider_android: 2.2.23` |
| `dart compile exe` 产物运行时报 `拒绝访问 errno 5` | 仓库在 Low Mandatory Level 目录，编译产物继承受限标签，连自己的数据目录都建不了 | 构建后 `icacls <exe> /setintegritylevel M`（build.ps1 已内置） |
| PowerShell 里方法名解析漏行 | 控制台按 GBK 解码 Dart 的 UTF-8 输出，多字节字符把换行吃掉 | 脚本里设 `[Console]::OutputEncoding = UTF8` |

### M1 开始前要知道的三件事

1. 内核现在**没有数据库**：`sqlite3` 还没进依赖（M0 刻意不加，先验证构建链）。
   加它需要同时解决 CLI 侧的 `sqlite3.dll` 分发（`packages/legado_cli/native/` + 拉取脚本）。
2. `Registry` 是显式注册，不存在 Go 反射那套 `RegisterService`；新增域要自己写
   `register()`，并继承 `CoreModule`（`name` / `dependsOn` / `migrate` / `register` / `close`）。
3. `check-methods.ps1` 默认只报告不失败（迁移期 UI 引用了 60+ 个尚未注册的方法），
   CI 里用 `-Strict`。

### M1 依赖决策（2026-11-19 修正上一条）

上表第 1 条的前提被实测推翻，记在这里免得后人再走一遍：

| 事实 | 影响 |
| --- | --- |
| `sqlite3 3.5.2` 走 **native assets**（build hooks 自动编译 sqlite3 源码），Windows 用 MSVC、Android 用 NDK | **不需要**自带 `sqlite3.dll`，也不需要 `sqlite3_flutter_libs` |
| `dart compile exe` 明确不支持 build hooks（报 `does not support build hooks, use 'dart build' instead`） | CLI 改用 `dart build cli`，产物从「单文件」变「`bundle/bin/legado.exe` + `bundle/lib/sqlite3.dll`」 |
| `dart build cli` 在 `dart run` 之外单独产出 bundle，exe 按 `../lib` 相对路径找 dll | `dist/cli/bundle/` 整个目录一起分发，不能只拷 exe |

`scripts/build.ps1 -Target cli` 已改为 `dart build cli`，并保留 `icacls /setintegritylevel M`
（Low Mandatory Level 目录的老问题）。

顺带的好处：`path_provider_android` 的 jni 与 sqlite 的 native 编译**互不相干**，
`sqlite3` 的 Android 编译只需 NDK（本机 29 已完整），不需要 CMake 那套装 NDK 的把戏。

## 九、相对 Go 版的净收益

1. **构建链简化**：Android 不再需要 Go + NDK + gomobile + AAR + Gradle 五段式；
   `flutter build apk` 一条命令。
2. **调试简化**：业务逻辑可在 `dart test` 里跑，不需要起进程、不需要 HTTP 回环。
3. **单语言**：UI 与逻辑同一语言，实体不需要两套 DTO 与手写序列化。
4. **体积**：省掉 29.6MB 的 `legado-core.exe` 与 AAR 里的 libgojni。
5. **代价**：规则引擎与格式解析要重写一遍（约 35k 行 Dart），且 JS 覆盖度需要实测。
