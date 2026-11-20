# AI 开发环境说明（国内镜像 + Flutter AI 工具链）

> 本文件由 WorkBuddy 依据 `docs.flutter.cn` 官方文档整理，适用于中国大陆网络环境下的 Flutter/Dart 开发。
> 完整版本见本机技能：`C:\Users\bingx\.workbuddy\skills\flutter-cn-ai-dev\SKILL.md`

## 一、国内镜像（已配置完毕）

### 环境变量（用户级，永久生效）

```bash
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
```

| 变量 | 作用 |
|------|------|
| `PUB_HOSTED_URL` | pub package 源（`pub.flutter-io.cn`） |
| `FLUTTER_STORAGE_BASE_URL` | Flutter 引擎产物、SDK 归档、Gradle `download.flutter.io` 源 |

### 为什么必须用 CFUG 镜像而不是 TUNA

镜像对 `download.flutter.io` 的覆盖情况直接决定能否构建成功：

| 镜像 | `download.flutter.io` | 结论 |
|------|----------------------|------|
| `storage.flutter-io.cn`（CFUG） | ✅ 200 | **本机使用** |
| `mirrors.tuna.tsinghua.edu.cn/flutter` | ❌ 404 | 引擎产物拉不到，构建卡死 |
| `storage.googleapis.com`（官方） | ✅ 200 | 可用但慢 |

Gradle 引擎仓库兜底已写入 `C:\Users\bingx\.gradle\init.gradle`（阿里云 / 腾讯云 Maven + `storage.flutter-io.cn/download.flutter.io`）。

### 发布到 pub.dev 的例外

镜像不支持发布。发布前需清掉 `PUB_HOSTED_URL` 并配置代理访问 pub.dev。

## 二、Flutter AI 工具链

### 四层机制

| 机制 | 范围 | 用途 |
|------|------|------|
| Agent skills | 按需加载 | 多步流程与模式（响应式布局、widget 测试写法） |
| Dart & Flutter MCP server | 本地 SDK | 实时诊断、符号解析、运行时自省、跑测试 |
| Developer Knowledge MCP | 云端文档 | 检索官方 Flutter/Dart 文档 |
| Package skills | 依赖包 | 第三方库用法 |

### 已安装内容

| 内容 | 路径 |
|------|------|
| 25 个官方 skills | `.agents/skills/` |
| hot reload 主动规则 | `.agents/rules/flutter-hot-reload.md` |
| MCP server 配置 | `.agents/mcp_config.json`、`.mcp.json` |
| 官方 skills 源 | `flutter/agent-plugins`、`dart-lang/skills` |

技能清单：`flutter-fix-layout-issues`、`flutter-build-responsive-layout`、`flutter-setup-declarative-routing`、`flutter-apply-architecture-best-practices`、`flutter-add-widget-test`、`flutter-add-integration-test`、`flutter-add-widget-preview`、`flutter-setup-localization`、`flutter-implement-json-serialization`、`flutter-use-http-package`、`dart-run-static-analysis`、`dart-fix-runtime-errors`、`dart-add-unit-test`、`dart-collect-coverage`、`dart-generate-test-mocks`、`dart-resolve-package-conflicts`、`dart-use-primary-constructors`、`dart-use-pattern-matching`、`dart-use-path-package`、`dart-use-doc-examples`、`dart-write-documentation`、`dart-build-cli-app`、`dart-setup-ffi-assets`、`dart-use-ffigen`、`dart-migrate-to-checks-package`。

### 重新安装官方 skills（GitHub 直连失败时）

```bash
cd /tmp
git clone --depth 1 https://github.com/flutter/agent-plugins.git flutter-agent-plugins
git clone --depth 1 https://github.com/dart-lang/skills.git dart-skills
cd <项目根>
npx --yes skills add /tmp/flutter-agent-plugins --skill '*' --agent universal --yes
npx --yes skills add /tmp/dart-skills --skill '*' --agent universal --yes
```

`npx skills add <github-url>` 会因 SSL 中断失败，**先 clone 到本地再从本地路径装**是可靠路径。

### MCP server 客户端配置位置

| 客户端 | 文件 | 键名 |
|--------|------|------|
| Cursor / 通用 | `.mcp.json` | `mcpServers` |
| VS Code + Copilot | `.vscode/mcp.json` | `servers` |
| Antigravity | `.agents/mcp_config.json` | `mcpServers` |
| Claude Code | `claude plugin marketplace add flutter/agent-plugins` | — |
| Codex | `codex plugin marketplace add flutter/agent-plugins` | — |

键名写错（VS Code 用 `servers`）是最常见的「配了不生效」原因。

### Package skills

```bash
dart run skills@ get
```

## 三、本机环境速查

| 项 | 值 |
|----|-----|
| Flutter | `C:\Users\bingx\fvm\versions\stable` → 3.38.3 stable |
| Dart | 3.10.1 stable |
| JDK | `C:\Program Files\Microsoft\jdk-21.0.7.6-hotspot`（Gradle 8.14 最高 LTS） |
| Android SDK | `C:\Users\bingx\AppData\Local\Android\Sdk` |

## 四、构建命令

```bash
cd C:/Users/bingx/work/code/legado/legado-flutter/app
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
  /c/Users/bingx/fvm/versions/stable/bin/flutter build apk --release --no-pub
```

`--no-pub` 必要：依赖已由 `pubspec.lock` 锁定，pub 走国内镜像偶尔会挂。

## 五、排障速查

| 症状 | 根因 | 处理 |
|------|------|------|
| `flutter pub get` 502 | `PUB_HOSTED_URL` 未设/不通 | 设 `https://pub.flutter-io.cn` |
| 构建卡在下载引擎产物 | `FLUTTER_STORAGE_BASE_URL` 指向 TUNA | 改 `https://storage.flutter-io.cn` |
| `Unsupported class file major version 69` | Gradle 撞 Java 25 | `org.gradle.java.home` 指向 JDK 21 |
| `Build was configured to prefer settings repositories...` | init.gradle 里用了 `allprojects { repositories }` | 只在 settings 层加仓库 |
| `CMake 3.22.1 not found` | Flutter 插件无条件 forceNdkDownload | `pip install cmake==3.22.1` |
| npx skills SSL 错误 | GitHub 直连中断 | 先 clone 再本地安装 |
| 模拟器起不来 | AVD 名带 `.1`；adb 端口未就绪 | `emulator -list-avds`；`adb connect 127.0.0.1:5554` |
