import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/core.dart';
import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 书架域的接线测试：17 个方法都从 Registry 走，不直接调 service。
/// 重点盯契约里最容易错的四件事：试读态、rowid 映射、进度哨兵、删书清理。
void main() {
  late Directory home;
  late StoreModule store;
  late ShelfModule shelf;
  late Registry registry;

  LegadoContext ctx([String? dir]) =>
      LegadoContext(homeDir: dir ?? home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-shelf-module');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    shelf = ShelfModule();
    shelf.register(registry, ctx());
  });

  tearDown(() async {
    await shelf.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<List<Map<String, Object?>>> callList(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as List).cast<Map<String, Object?>>();

  /// 插一本书并返回对外 rowid。
  int addBook(
    String url, {
    String name = '测试书',
    int type = BookType.text,
    int group = 0,
    int total = 4,
    String? localPath,
  }) {
    final existing = store.daos.book.idOf(url);
    if (existing != null) return existing;
    store.daos.book.insert(
      Book(
        bookUrl: url,
        name: name,
        author: '作者',
        origin: localPath == null ? 'https://example.test/s' : BookType.localTag,
        type: localPath == null ? type : type | BookType.local,
        group: group,
        totalChapterNum: total,
      ),
    );
    return store.daos.book.idOf(url)!;
  }

  test('依赖与 17 个方法都已注册', () {
    expect(shelf.name, 'shelf');
    expect(shelf.dependsOn, contains('store'));
    expect(
      registry.all.map((m) => m.name).where((n) => n.startsWith('Shelf.')).toSet(),
      {
        'Shelf.ListGroups',
        'Shelf.ListBooks',
        'Shelf.GetBook',
        'Shelf.PutOnShelf',
        'Shelf.DeleteBook',
        'Shelf.MoveToGroup',
        'Shelf.SaveProgress',
        'Shelf.GetProgress',
        'Shelf.SaveBook',
        'Shelf.CreateGroup',
        'Shelf.UpdateGroup',
        'Shelf.DeleteGroup',
        'Shelf.SetCanUpdate',
        'Shelf.MoveToGroups',
        'Shelf.AddToGroups',
        'Shelf.DeleteBooks',
        'Shelf.ExportBookshelf',
      },
    );
  });

  test('SaveBook：改书名/作者/封面/简介落库，留空则清掉自定义字段', () async {
    final id = addBook('https://example.test/edit');

    final saved =
        await call('Shelf.SaveBook', [
              id,
              '  新书名  ',
              ' 新作者 ',
              'https://example.test/c.jpg',
              '新的简介',
              0,
            ])
            as Map<String, Object?>;
    expect(saved['name'], '新书名'); // 首尾空白被 trim
    expect(saved['author'], '新作者');
    expect(saved['intro'], '新的简介');

    final book = store.daos.book.getById(id)!;
    expect(book.name, '新书名');
    expect(book.customCoverUrl, 'https://example.test/c.jpg');
    expect(book.customIntro, '新的简介');

    // 封面/简介传空串 → 清空（回到书源给的默认值）
    await call('Shelf.SaveBook', [id, '新书名', '新作者', '', '']);
    final cleared = store.daos.book.getById(id)!;
    expect(cleared.customCoverUrl, isNull);
    expect(cleared.customIntro, isNull);

    // groupId 传 -1 表示"不动分组"
    expect(cleared.group, 0);
  });

  test('SaveBook：空书名 / 同名同作者 / 分组不存在各自报错', () async {
    final id = addBook('https://example.test/a1', name: '甲书');
    addBook('https://example.test/a2', name: '乙书');

    await expectLater(
      call('Shelf.SaveBook', [id, '   ', '作者', '', '']),
      throwsA(
        isA<LegadoException>()
            .having((e) => e.code, 'code', ErrorCode.invalid)
            .having((e) => e.message, 'message', contains('书名不能为空')),
      ),
    );

    await expectLater(
      call('Shelf.SaveBook', [id, '乙书', '作者', '', '']),
      throwsA(
        isA<LegadoException>()
            .having((e) => e.code, 'code', ErrorCode.invalid)
            .having((e) => e.message, 'message', contains('同名同作者')),
      ),
    );

    await expectLater(
      call('Shelf.SaveBook', [id, '甲书', '作者', '', '', 999]),
      throwsA(
        isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.notFound),
      ),
    );
  });

  test('试读书不进书架，GetBook 可读，PutOnShelf 后转正', () async {
    final url = 'https://example.test/preview';
    final id = addBook(url, type: BookType.text | BookType.notShelf);

    expect(await callList('Shelf.ListBooks', [0]), isEmpty);
    final detail = await call('Shelf.GetBook', [id]) as Map<String, Object?>;
    expect(detail['inShelf'], isFalse);
    expect(detail['bookUrl'], url);

    await call('Shelf.PutOnShelf', [id]);
    final books = await callList('Shelf.ListBooks', [0]);
    expect(books, hasLength(1));
    expect(books.single['id'], id);
    expect(books.single['inShelf'], isTrue);
  });

  test('分组是位域：一本书可属于多个分组，groupID=0 取全部', () async {
    store.daos.bookGroup.insert(
      BookGroup(groupId: 4, groupName: '第二组', order: 1, show: true),
    );
    final url = 'https://example.test/grouped';
    addBook(url, group: 2 | 4);

    expect(await callList('Shelf.ListBooks', [0]), hasLength(1));
    expect(await callList('Shelf.ListBooks', [2]), hasLength(1));
    expect(await callList('Shelf.ListBooks', [4]), hasLength(1));
    expect(await callList('Shelf.ListBooks', [8]), isEmpty);
  });

  test('摘要带齐 UI 字段：百分比、格式、本地文件缺失', () async {
    final url = 'https://example.test/detail';
    addBook(url);
    store.daos.book.insert(
      Book(
        bookUrl: url,
        name: '测试书',
        author: '作者',
        origin: 'https://example.test/s',
        type: BookType.text,
        totalChapterNum: 4,
        durChapterIndex: 1,
        durChapterTitle: '第二章',
        durChapterTime: 1700000000000,
        intro: '简介',
        coverUrl: 'https://example.test/cover.jpg',
      ),
    );
    // INSERT OR REPLACE 会换 rowid，插完再取一次，别拿旧 ID 断言。
    final id = store.daos.book.idOf(url)!;

    final brief = (await callList('Shelf.ListBooks', [0])).single;
    expect(brief['id'], id);
    expect(brief['percent'], 50);
    expect(brief['durChapterTitle'], '第二章');
    expect(brief['isAudio'], isFalse);
    expect(brief['lastReadAt'], isA<String>());
    expect(brief['cover'], 'https://example.test/cover.jpg');

    final localFile = File('${home.path}/local.txt');
    localFile.writeAsStringSync('正文');
    final localUrl = addBook(localFile.path, localPath: localFile.path);
    final localBrief = (await callList('Shelf.ListBooks', [0]))
        .firstWhere((b) => b['id'] == localUrl);
    expect(localBrief['fileMissing'], isFalse);
    localFile.deleteSync();
    final missing = (await callList('Shelf.ListBooks', [0]))
        .firstWhere((b) => b['id'] == localUrl);
    expect(missing['fileMissing'], isTrue);
  });

  test('进度：无记录是 -1；保存后双表一致；越界百分比钳到 100', () async {
    final url = 'https://example.test/progress';
    final id = addBook(url);

    final empty = await call('Shelf.GetProgress', [id]) as Map<String, Object?>;
    expect(empty['chapterIndex'], -1);

    await call('Shelf.SaveProgress', [id, 2, '第三章', 128, 37.5]);
    final got = await call('Shelf.GetProgress', [id]) as Map<String, Object?>;
    expect(got['bookId'], id);
    expect(got['chapterIndex'], 2);
    expect(got['chapterTitle'], '第三章');
    expect(got['chapterPos'], 128);
    expect(got['scrollPercent'], 37.5);

    final book = store.daos.book.getById(id)!;
    expect(book.durChapterIndex, 2);
    expect(book.durChapterTitle, '第三章');
    expect(book.durChapterPos, 128);
    expect(store.daos.readingProgress.get(url)!.updatedAt, greaterThan(0));

    await call('Shelf.SaveProgress', [id, 3, '第四章', 0, 180]);
    expect(
      (await call('Shelf.GetProgress', [id]) as Map)['scrollPercent'],
      100.0,
    );

    await expectLater(
      call('Shelf.GetProgress', [0]),
      throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.invalid)),
    );
    // 契约只把 bookID=0 当参数错；查不到的书同样按「没有进度」处理，
    // 阅读器拿着过期 ID 打开时不该被一个异常挡住。
    final orphan = await call('Shelf.GetProgress', [9999]) as Map<String, Object?>;
    expect(orphan['chapterIndex'], -1);
  });

  test('删书：章节 / 进度 / 缓存 / 磁盘图片一起清', () async {
    final url = 'https://example.test/delete';
    final id = addBook(url);
    store.daos.chapter.insert(
      BookChapter(url: '$url/1', bookUrl: url, title: '第一章', index: 0),
    );
    await call('Shelf.SaveProgress', [id, 0, '第一章', 0, 12.5]);
    store.daos.cache.put('chapter_${id}_0', 'cached');
    store.daos.cache.put('chapter_${id + 1}_0', 'keep me');
    final imageDir = Directory('${home.path}/cache/chapter/$id/0');
    imageDir.createSync(recursive: true);
    File('${imageDir.path}/001.jpg').writeAsBytesSync(<int>[1, 2, 3]);

    await call('Shelf.DeleteBook', [id]);

    expect(store.daos.book.has(url), isFalse);
    expect(store.daos.chapter.getChapterCount(url), 0);
    expect(store.daos.readingProgress.get(url), isNull);
    expect(store.daos.cache.get('chapter_${id}_0'), isNull);
    expect(store.daos.cache.get('chapter_${id + 1}_0')?.value, 'keep me');
    expect(Directory('${home.path}/cache/chapter/$id').existsSync(), isFalse);
  });

  test('分组 CRUD：内置组不可动，删组不清书', () async {
    final url = 'https://example.test/group-crud';
    final id = addBook(url, group: 2);

    final created = await call('Shelf.CreateGroup', ['新分组']) as Map<String, Object?>;
    final groupId = created['id'] as int;
    expect(groupId, greaterThan(1)); // 1 预留给内置「全部」
    expect(created['name'], '新分组');
    expect((await callList('Shelf.ListGroups')).map((g) => g['id']), contains(groupId));

    // 前四个参数是老契约；后三个是分组管理新增的可选项。
    await call('Shelf.UpdateGroup', [groupId, '改名', false, 7]);
    await call('Shelf.UpdateGroup', [
      groupId, '改名', false, 7, '/cover.png', 3, false,
    ]);
    final updated = (await callList('Shelf.ListGroups'))
        .firstWhere((g) => g['id'] == groupId);
    expect(updated['name'], '改名');
    expect(updated['show'], isFalse);
    expect(updated['order'], 7);
    expect(updated['cover'], '/cover.png');
    expect(updated['bookSort'], 3);
    expect(updated['enableRefresh'], isFalse);

    await call('Shelf.MoveToGroup', [id, groupId]);
    expect(store.daos.book.getById(id)!.group, groupId);

    await call('Shelf.DeleteGroup', [groupId]);
    expect(store.daos.book.getById(id)!.group, 0);
    expect(store.daos.book.getById(id), isNotNull);
    expect(
      (await callList('Shelf.ListGroups')).map((g) => g['id']),
      isNot(contains(groupId)),
    );

    for (final method in ['Shelf.DeleteGroup', 'Shelf.UpdateGroup']) {
      await expectLater(
        call(method, method.endsWith('DeleteGroup') ? [1] : [1, 'x', true, 0]),
        throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.invalid)),
      );
    }
  });

  test('书架管理批量：移动/加入分组、开关更新、批量删除', () async {
    final ids = [
      addBook('https://example.test/batch/1', name: '批量一', group: 2),
      addBook('https://example.test/batch/2', name: '批量二', group: 4),
    ];
    final g2 = await call('Shelf.CreateGroup', ['甲组']) as Map<String, Object?>;
    final g4 = await call('Shelf.CreateGroup', ['乙组']) as Map<String, Object?>;
    final gid2 = g2['id'] as int;
    final gid4 = g4['id'] as int;

    await call('Shelf.MoveToGroups', [ids, gid2]);
    expect(store.daos.book.getById(ids[0])!.group, gid2);
    expect(store.daos.book.getById(ids[1])!.group, gid2);

    await call('Shelf.AddToGroups', [ids, gid4]);
    expect(store.daos.book.getById(ids[0])!.group, gid2 | gid4);
    expect(store.daos.book.getById(ids[1])!.group, gid2 | gid4);

    await call('Shelf.SetCanUpdate', [ids, false]);
    expect(store.daos.book.getById(ids[0])!.canUpdate, isFalse);
    expect(store.daos.book.getById(ids[1])!.canUpdate, isFalse);
    await call('Shelf.SetCanUpdate', [ids, true]);
    expect(store.daos.book.getById(ids[0])!.canUpdate, isTrue);

    await call('Shelf.DeleteBooks', [ids]);
    expect(store.daos.book.getById(ids[0]), isNull);
    expect(store.daos.book.getById(ids[1]), isNull);
  });

  test('ListBooks 按 bookSort 排序，ExportBookshelf 输出原版 books.json 格式', () async {
    final a = addBook('https://example.test/a', name: '甲书');
    final b = addBook('https://example.test/b', name: '乙书');
    final bookA = store.daos.book.getById(a)!;
    bookA.durChapterTime = 2000;
    // 原版 sort=1 排的是 `latestChapterTime`（目录最近更新时间），不是 lastCheckTime。
    bookA.latestChapterTime = 1000;
    bookA.order = 2;
    store.daos.book.update(bookA);
    final bookB = store.daos.book.getById(b)!;
    bookB.durChapterTime = 1000;
    bookB.latestChapterTime = 3000;
    bookB.order = 1;
    store.daos.book.update(bookB);

    // -1 走 DAO 默认顺序（按 order），0 按阅读时间，1 按目录更新时间，
    // 2 按书名，3 按 order，4 综合（取两个时间的最大值），5 按作者。
    expect((await callList('Shelf.ListBooks', [0, -1])).first['name'], '乙书');
    expect((await callList('Shelf.ListBooks', [0, 0])).first['name'], '甲书');
    expect((await callList('Shelf.ListBooks', [0, 1])).first['name'], '乙书');
    expect((await callList('Shelf.ListBooks', [0, 4])).first['name'], '乙书');
    expect((await callList('Shelf.ListBooks', [0, 3])).first['name'], '乙书');
    // Dart String.compareTo 按码点排，「乙」(U+4E59) 在「甲」(U+7532) 前。
    expect((await callList('Shelf.ListBooks', [0, 2])).first['name'], '乙书');

    final json = await call('Shelf.ExportBookshelf', [0]) as String;
    final rows = (jsonDecode(json) as List).cast<Map<String, Object?>>();
    expect(rows.length, 2);
    expect(
      rows.first.keys.toSet(),
      {'name', 'author', 'intro'},
      reason: '与原版 exportBookshelf 完全同格式，才能互相导入',
    );
  });

  test('LegadoCore 完整装配后 Shelf 方法可用', () async {
    final otherHome = await Directory.systemTemp.createTemp('legado-shelf-core');
    final core = LegadoCore.instance;
    addTearDown(() async {
      await core.close();
      if (otherHome.existsSync()) otherHome.deleteSync(recursive: true);
    });

    await core.init(homeDir: otherHome.path, version: 'test', host: 'test');
    expect(
      core.methods('Shelf').map((m) => m.name),
      contains('Shelf.ListBooks'),
    );
    expect(await core.call('Shelf.ListGroups'), isEmpty);
  });
}
