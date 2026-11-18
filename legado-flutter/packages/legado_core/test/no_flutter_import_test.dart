import 'dart:io';

import 'package:test/test.dart';

/// 内核必须是纯 Dart：一旦引了 Flutter，CLI 模式就跑不起来，
/// 「双端共用一份逻辑」这个前提也就没了。
///
/// 用测试而不是 code review 守这条线，是因为违反它的代价在很久以后才显现
/// （某天想 `dart run` 才发现跑不动），而那时已经很难回头拆。
void main() {
  test('legado_core 不得依赖 Flutter', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '请在 packages/legado_core 下运行');

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
