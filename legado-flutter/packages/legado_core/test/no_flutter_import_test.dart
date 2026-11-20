import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// 内核必须是纯 Dart：一旦引了 Flutter，CLI 模式就跑不起来，
/// 「双端共用一份逻辑」这个前提也就没了。
///
/// 用测试而不是 code review 守这条线，是因为违反它的代价在很久以后才显现
/// （某天想 `dart run` 才发现跑不动），而那时已经很难回头拆。
///
/// 定位 `lib/` 走 `package:` URI，不用 `Directory('lib')`：测试既可能从工作区根
/// （`dart test packages/legado_core/test`）启动，也可能从包根启动，相对路径在
/// 第一种情况下会误报「lib 不存在」——误报的守卫比没有守卫更糟。
void main() {
  test('legado_core 不得依赖 Flutter', () async {
    final entry = await Isolate.resolvePackageUri(
      Uri.parse('package:legado_core/legado_core.dart'),
    );
    expect(entry, isNotNull, reason: '解析不到 package:legado_core，检查 pubspec 的 name');

    final lib = Directory.fromUri(entry!.resolve('.'));
    expect(lib.existsSync(), isTrue, reason: 'lib 目录不存在: ${lib.path}');

    final offenders = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      if (src.contains('package:flutter/') ||
          src.contains("import 'dart:ui'") ||
          src.contains('import "dart:ui"')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty, reason: '这些文件引入了 Flutter/UI 依赖，CLI 会失效');
  });
}
