import 'dart:io';

import 'package:legado_core/src/core.dart';
import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/bookmark/bookmark_module.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 书签 / 阅读记录域的接线测试：9 个方法、参数收敛、落库、
/// 当前位置解析（chapterIndex<0）与统计口径。
void main() {
  late Directory home;
  late StoreModule store;
  late ShelfModule shelf;
  late BookmarkModule bookmark;
  late Registry registry;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-bookmark-module');
    store = StoreModule();
    await store.migrate(ctx());
    // BookmarkModule 的 ProgressReader 通过 ShelfModule.instance 取进度。
    shelf = ShelfModule();
    registry = Registry();
    shelf.register(registry, ctx());
    bookmark = BookmarkModule();
    bookmark.register(registry, ctx());
  });

  tearDown(() async {
    await bookmark.close();
    await shelf.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<List<Map<String, Object?>>> callList(
    String method, [
    List<Object?> args = const [],
  ]) async {
    final result = await call(method, args);
    return (result as List<Object?>).cast<Map<String, Object?>>();
  }

  /// 插一本书并设进度，返回 rowid。
  int addBookWithProgress(int chapterIndex) {
    const url = 'https://example.test/book';
    store.daos.book.insert(Book(
      bookUrl: url,
      name: '测试书',
      author: '作者',
      origin: 'https://example.test/s',
      type: BookType.text,
      totalChapterNum: 10,
    ));
    final id = store.daos.book.idOf(url)!;
    store.daos.readingProgress.put(ReadingProgress(
      bookUrl: url,
      chapterIndex: chapterIndex,
      chapterTitle: '第 $chapterIndex 章',
      chapterPos: 12,
      scrollPercent: 30,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    return id;
  }

  test('依赖声明：bookmark 依赖 store 与 shelf', () {
    expect(bookmark.name, 'bookmark');
    expect(bookmark.dependsOn, containsAll(<String>['store', 'shelf']));
  });

  test('9 个方法都挂上了', () {
    expect(
      registry.all.map((m) => m.name),
      containsAll(<String>[
        'Bookmark.Add',
        'Bookmark.List',
        'Bookmark.Remove',
        'Bookmark.UpdateNote',
        'Bookmark.Count',
        'Record.Append',
        'Record.List',
        'Record.Clear',
        'Record.Stats',
      ]),
    );
  });

  test('书签增改删查与计数：createdAt 是 RFC3339', () async {
    final id = addBookWithProgress(3);

    final added = await call('Bookmark.Add', [
      id,
      1,
      '第一章',
      25,
      '摘录内容',
      '想法',
    ]) as Map<String, Object?>;
    expect(added['bookId'], id);
    expect(added['chapterIndex'], 1);
    expect(added['chapterPos'], 25);
    expect(added['note'], '想法');
    expect(added['id'], isA<int>());
    expect(DateTime.tryParse(added['createdAt'] as String), isNotNull);

    await call('Bookmark.UpdateNote', [added['id'], '新备注']);
    var list = await callList('Bookmark.List', [id, 20]);
    expect(list.single['note'], '新备注');
    expect(list.single['content'], '摘录内容');

    expect(await call('Bookmark.Count', [id]), 1);
    await call('Bookmark.Remove', [added['id']]);
    list = await callList('Bookmark.List', [id, 20]);
    expect(list, isEmpty);
    expect(await call('Bookmark.Count', [id]), 0);
  });

  test('chapterIndex<0 解析为当前进度', () async {
    final id = addBookWithProgress(4);
    final added = await call('Bookmark.Add', [id, -1, '', 0, '', ''])
        as Map<String, Object?>;
    expect(added['chapterIndex'], 4);
  });

  test('删不到的书签抛 NOT_FOUND；bookId=0 汇总全部', () async {
    final id = addBookWithProgress(0);
    await call('Bookmark.Add', [id, 0, '标题', 0, '正文', '']);
    final all = await callList('Bookmark.List', [0, 20]);
    expect(all.length, 1);

    await expectLater(
      call('Bookmark.Remove', [9999]),
      throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.notFound)),
    );
  });

  test('阅读记录：同书同日同章去重并刷新时间，倒序分页', () async {
    final id = addBookWithProgress(2);
    await call('Record.Append', [id, '测试书', 1, '第一章']);
    await call('Record.Append', [id, '测试书', 1, '第一章改名']);
    var list = await callList('Record.List', [0, 20]);
    expect(list.length, 1);
    expect(list.single['chapterTitle'], '第一章改名');
    expect(list.single['bookId'], id);
    expect(DateTime.tryParse(list.single['readAt'] as String), isNotNull);

    // 换章追加一条，倒序时新章在前。
    await call('Record.Append', [id, '测试书', 2, '第二章']);
    list = await callList('Record.List', [0, 20]);
    expect(list.map((e) => e['chapterIndex']).toList(), [2, 1]);
    expect((await callList('Record.List', [1, 1])).single['chapterIndex'], 1);
  });

  test('Record.Stats 与 Clear：天数按有阅读的日子算，0 = 全清', () async {
    final id = addBookWithProgress(0);
    await call('Record.Append', [id, '测试书', 0, '第一章']);
    await call('Record.Append', [id, '测试书', 1, '第二章']);

    var stats = await call('Record.Stats') as Map<String, Object?>;
    expect(stats['days'], 1);
    expect(stats['books'], 1);
    expect(stats['records'], 2);

    final removed = await call('Record.Clear', [0]) as int;
    expect(removed, 2);
    stats = await call('Record.Stats') as Map<String, Object?>;
    expect(stats['records'], 0);
    expect(stats['days'], 0);
  });

  test('Record.Append 的 chapterIndex<0 也读当前进度', () async {
    final id = addBookWithProgress(6);
    await call('Record.Append', [id, '测试书', -1, '']);
    final list = await callList('Record.List', [0, 10]);
    expect(list.single['chapterIndex'], 6);
  });

  test('经 LegadoCore 全链路也能调到书签方法', () async {
    await LegadoCore.instance.init(homeDir: home.path, version: 'test');
    try {
      expect(LegadoCore.instance.methods().map((m) => m.name),
          contains('Bookmark.Add'));
      final added = await LegadoCore.instance.call('Bookmark.Add', [1, 0, '标题', 0, '', '']);
      expect((added as Map<String, Object?>)['chapterIndex'], 0);
    } finally {
      await LegadoCore.instance.close();
    }
  });
}
