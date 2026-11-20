import 'dart:io';

import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/store/schema.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 只 import `src/core.dart` 以下的内核部分，不经过 `legado_core.dart`：
/// 门面还导出了 JS 引擎，并行开发期间它可能暂时编译不过，
/// 数据层的测试不应该被别的域的编译错误拖住。
void main() {
  late Directory home;
  late StoreModule module;
  late Registry registry;

  LegadoContext ctx() => LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-store-module');
    module = StoreModule();
    registry = Registry();
  });

  tearDown(() async {
    await module.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test('migrate 后 System.Database 返回版本、路径与各表行数', () async {
    await module.migrate(ctx());
    module.register(registry, ctx());

    final info = await registry.invoke('System.Database', const []) as Map<String, Object?>;
    expect(info['version'], schemaVersion);
    expect(info['path'], endsWith('legado.db'));
    final tables = info['tables'] as Map<String, Object?>;
    expect(tables.keys.toSet(), dataTableNames.toSet());
    expect(tables['books'], 0);
  });

  test('DAO 写入后 System.Database 行数同步变化', () async {
    await module.migrate(ctx());
    module.register(registry, ctx());

    module.daos.book.insert(Book(bookUrl: 'b1', name: '书', author: '作者'));
    final info = await registry.invoke('System.Database', const []) as Map<String, Object?>;
    expect((info['tables'] as Map<String, Object?>)['books'], 1);
  });

  test('close 后重新 migrate 能打开同一个库并读到旧数据', () async {
    await module.migrate(ctx());
    module.daos.book.insert(Book(bookUrl: 'b1', name: '书', author: '作者'));
    await module.close();

    final reopened = StoreModule();
    addTearDown(reopened.close);
    await reopened.migrate(ctx());
    expect(reopened.daos.book.getBook('b1')?.name, '书');
    expect(File('${home.path}/legado.db').existsSync(), isTrue);
  });

  test('未 migrate 就访问 database 给出明确错误', () {
    expect(() => module.database, throwsA(isA<StateError>()));
    expect(() => module.daos, throwsA(isA<StateError>()));
  });
}
