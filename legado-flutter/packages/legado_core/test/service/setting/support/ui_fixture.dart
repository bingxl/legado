import 'dart:convert';
import 'dart:io';

/// 定位 Flutter UI 的测试 fixture。
///
/// `dart test` 的工作目录随调用方式而变（包根 `packages/legado_core` 或仓库根），
/// 所以不写死相对路径：从当前目录逐级向上找包含 `app/test/fixtures` 的目录。
/// 找不到就明确报错——静默跳过会让「与 UI 对齐」这条最重要的断言悄悄失效。
File uiFixtureFile(String name) {
  var dir = Directory.current;
  for (var depth = 0; depth < 6; depth++) {
    for (final candidate in <File>[
      File('${dir.path}/app/test/fixtures/$name'),
      File('${dir.path}/legado-flutter/app/test/fixtures/$name'),
    ]) {
      if (candidate.existsSync()) return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('找不到 UI fixture $name（cwd=${Directory.current.path}）');
}

Map<String, dynamic> uiFixture(String name) =>
    jsonDecode(uiFixtureFile(name).readAsStringSync()) as Map<String, dynamic>;
