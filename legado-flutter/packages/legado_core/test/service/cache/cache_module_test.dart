import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/cache/cache_module.dart';
import 'package:legado_core/src/service/library/library_module.dart';
import 'package:legado_core/src/service/reader/reader_module.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 缓存域接线测试：10 个方法 + 后台任务真实落库 + 清理。
void main() {
  late Directory home;
  late StoreModule store;
  late ShelfModule shelf;
  late ReaderModule reader;
  late LibraryModule library;
  late CacheModule cache;
  late Registry registry;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-cache-module');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    shelf = ShelfModule();
    shelf.register(registry, ctx());
    reader = ReaderModule();
    reader.register(registry, ctx());
    library = LibraryModule();
    library.register(registry, ctx());
    cache = CacheModule();
    cache.register(registry, ctx());
  });

  tearDown(() async {
    await cache.close();
    await library.close();
    await reader.close();
    await shelf.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<Map<String, Object?>> callMap(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as Map).cast<String, Object?>();

  Future<List<Map<String, Object?>>> callList(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as List).cast<Map<String, Object?>>();

  /// 导入一本本地 txt，返回 bookId 与章节数。
  Future<(int, int)> importBook() async {
    final file = File('${home.path}${Platform.pathSeparator}cache-book.txt');
    file.writeAsStringSync(
      '第一章 开端\n正文第一段。\n第二行。\n'
      '第二章 发展\n更多正文。\n'
      '第三章 结局\n完。\n',
      encoding: utf8,
    );
    final result = await callMap('Library.ImportLocalFiles', [
      [file.path],
      0,
    ]);
    final imported = (result['imported'] as List).cast<Map<String, Object?>>();
    return (imported.single['id'] as int, imported.single['totalChapters'] as int);
  }

  /// 等后台任务离开 running（最多 2 秒）。
  Future<Map<String, Object?>> waitJob(int bookId) async {
    for (var i = 0; i < 200; i++) {
      final jobs = await callList('Cache.Jobs');
      for (final job in jobs) {
        if (job['bookId'] == bookId && job['state'] != 'running') {
          return job;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('缓存任务 2 秒内没有结束');
  }

  test('依赖与 10 个方法注册', () {
    expect(cache.name, 'cache');
    expect(cache.dependsOn, containsAll(<String>['store', 'shelf', 'reader']));
    expect(
      registry.all.map((m) => m.name),
      containsAll(<String>[
        'Cache.Start',
        'Cache.Cancel',
        'Cache.Jobs',
        'Cache.Stats',
        'Cache.Books',
        'Cache.Chapters',
        'Cache.Status',
        'Cache.Delete',
        'Cache.PurgeBook',
        'Cache.Clear',
      ]),
    );
  });

  test('Start 立即回执；后台把章节落库，Stats/Chapters/Books 可查', () async {
    final (bookId, _) = await importBook();

    final job = await callMap('Cache.Start', [bookId, 'chapters', [0, 1]]);
    expect(job['bookId'], bookId);
    expect(job['scope'], 'chapters');
    expect(job['total'], 2);
    expect(job['state'], anyOf('running', 'done'));
    expect(DateTime.tryParse(job['startedAt'] as String), isNotNull);

    final finished = await waitJob(bookId);
    expect(finished['state'], 'done');
    expect(finished['done'], 2);
    expect(finished['failed'], 0);

    final chapters = await callList('Cache.Chapters', [bookId]);
    expect(chapters.length, 2);
    expect(chapters.map((e) => e['index']).toList(), [0, 1]);
    expect(chapters.first['title'], isNotEmpty);
    expect(chapters.first['size'], greaterThan(0));

    final status = await callMap('Cache.Status', [bookId]);
    expect(status['cachedChapters'], 2);
    expect(status['size'], greaterThan(0));

    final stats = await callMap('Cache.Stats');
    expect(stats['books'], 1);
    expect(stats['chapters'], 2);

    final books = await callList('Cache.Books');
    expect(books.length, 1);
    expect(books.single['bookId'], bookId);
    expect(books.single['cachedChapters'], 2);
    expect(books.single['name'], isNotEmpty);
  });

  test('scope=all 缓存整本；missing 只补未缓存的', () async {
    final (bookId, total) = await importBook();
    expect(total, greaterThanOrEqualTo(2));

    await call('Cache.Start', [bookId, 'all', const <int>[]]);
    expect((await waitJob(bookId))['state'], 'done');
    expect((await callList('Cache.Chapters', [bookId])).length, total);
    expect((await callMap('Cache.Status', [bookId]))['cachedChapters'], total);

    // 全缓存后再 missing：没有需要缓存的章节，抛 INVALID_ARGUMENT。
    await expectLater(
      call('Cache.Start', [bookId, 'missing', const <int>[]]),
      throwsA(isA<LegadoException>()
          .having((e) => e.code, 'code', ErrorCode.invalid)),
    );
  });

  test('参数校验：bookID 缺失/未知 scope/未知书', () async {
    await expectLater(
      call('Cache.Start', [0, 'all', const <int>[]]),
      throwsA(isA<LegadoException>()),
    );
    await expectLater(
      call('Cache.Start', [1, 'unknown', const <int>[]]),
      throwsA(isA<LegadoException>()
          .having((e) => e.code, 'code', ErrorCode.invalid)),
    );
    await expectLater(
      call('Cache.Start', [9999, 'all', const <int>[]]),
      throwsA(isA<LegadoException>()
          .having((e) => e.code, 'code', ErrorCode.notFound)),
    );
  });

  test('Delete 空 indexes 什么也不做；删除单章后统计同步', () async {
    final (bookId, _) = await importBook();
    await call('Cache.Start', [bookId, 'chapters', [0, 1]]);
    await waitJob(bookId);

    await call('Cache.Delete', [bookId, const <int>[]]);
    expect((await callList('Cache.Chapters', [bookId])).length, 2);

    await call('Cache.Delete', [bookId, [0]]);
    expect((await callList('Cache.Chapters', [bookId])).length, 1);
    expect((await callMap('Cache.Stats'))['chapters'], 1);
  });

  test('Cancel 幂等；PurgeBook 与 Clear 清干净', () async {
    final (bookId, _) = await importBook();
    await call('Cache.Cancel', [bookId]); // 没有任务也成功

    await call('Cache.Start', [bookId, 'chapters', [0, 1]]);
    await waitJob(bookId);
    await call('Cache.PurgeBook', [bookId]);
    expect(await callList('Cache.Chapters', [bookId]), isEmpty);

    await call('Cache.Start', [bookId, 'chapters', [0]]);
    await waitJob(bookId);
    await call('Cache.Clear');
    final stats = await callMap('Cache.Stats');
    expect(stats['books'], 0);
    expect(stats['chapters'], 0);
    expect(stats['size'], 0);
    expect(stats['running'], 0);
    expect(await callList('Cache.Books'), isEmpty);
    expect(await callList('Cache.Jobs'), isNotEmpty); // 历史任务保留
  });
}
