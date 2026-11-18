# legado-flutter

纯 Dart 内核 + Flutter 应用的 pub workspace。原版 legado 的全部功能都在这里重写，
非 UI 逻辑集中在内核包里，因此**同一个功能既能被 App 调用，也能用 CLI 跑**。

```
legado-flutter/
├── pubspec.yaml              # workspace 根：一个 lockfile 管三个包
├── packages/
│   ├── legado_core/          # 纯 Dart 内核（禁止 import flutter，有测试守着）
│   │   └── lib/src/{kernel,modules,domain,rules,js,net,store,service}/
│   └── legado_cli/           # CLI 宿主：info / methods / call / serve
└── app/                      # Flutter 应用（android/ windows/）
```

## 常用命令

```powershell
# 依赖（本机代理连不上 pub.dev，需要镜像）
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
cd legado-flutter
flutter pub get

# 内核与 CLI —— 不需要 Flutter 环境
cd packages/legado_core; dart test
cd packages/legado_cli;  dart run bin/legado.dart methods
dart run bin/legado.dart call System.Echo '["hi"]'

# 应用
cd app
flutter analyze; flutter test
flutter run -d windows
flutter build apk --debug
```

## 两条硬规则

1. **内核不许依赖 Flutter**。`packages/legado_core/test/no_flutter_import_test.dart`
   会扫描源码，出现 `package:flutter` 或 `dart:ui` 即失败。破坏它等于让 CLI 失效。
2. **方法名是字符串契约**。UI 与 CLI 都用 `'Domain.Verb' + 位置参数` 调用内核，
   编译期查不出拼错，所以改动后跑 `pwsh -File ../scripts/check-methods.ps1`
   （迁移期默认只报告，`-Strict` 才作为失败）。

## 数据目录

CLI 与 App 用同一套优先级：`--dart-define=LEGADO_HOME` > 环境变量 `LEGADO_HOME` >
App 私有目录（`getApplicationSupportDirectory()`）。这样同一份数据可以用两种形态打开。

## 构建

仓库根 `scripts/build.ps1` 是唯一入口（Windows/Android/CLI 三选一）。
不再有 Go、gomobile、AAR、NDK —— `flutter build` 一条命令到底。
