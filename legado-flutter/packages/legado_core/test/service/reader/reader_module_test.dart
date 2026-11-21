import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/reader/reader_module.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

import '../../format/support/fixtures.dart';

/// 阅读器域测试：目录、本地 txt 正文、进度委托、大纲整表回写。
/// 网络书正文要等 Source 域，这里只验证它明确报 NOT_IMPLEMENTED。
void main() {
  late Directory home;
  late StoreModule store;
  late ShelfModule shelf;
  late ReaderModule reader;
  late Registry registry;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-reader-module');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    shelf = ShelfModule();
    shelf.register(registry, ctx());
    reader = ReaderModule();
    reader.register(registry, ctx());
  });

  tearDown(() async {
    await reader.close();
    await shelf.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<List<Map<String, Object?>>> callList(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as List).cast<Map<String, Object?>>();

  /// 造一本两章的本地 txt，start/end 用真实 UTF-8 字节偏移。
  (int, String) makeLocalBook() {
    const text = '第一章 起点\n正文第一段 & <特殊字符>\n第二行\n\n'
        '第二章 终点\n正文第二段\n';
    final file = File('${home.path}/sample.txt');
    file.writeAsStringSync(text, encoding: utf8);
    final bytes = utf8.encode(text);
    final firstEnd =
        utf8.encode(text.substring(0, text.indexOf('第二章 终点'))).length;

    store.daos.book.insert(
      Book(
        bookUrl: file.path,
        name: '样例',
        author: '测试',
        origin: BookType.localTag,
        type: BookType.local | BookType.text,
        totalChapterNum: 2,
      ),
    );
    store.daos.chapter.insertAll([
      BookChapter(
        url: '${file.path}#0',
        bookUrl: file.path,
        index: 0,
        title: '第一章 起点',
        start: 0,
        end: firstEnd,
      ),
      BookChapter(
        url: '${file.path}#1',
        bookUrl: file.path,
        index: 1,
        title: '第二章 终点',
        start: firstEnd,
        end: bytes.length,
      ),
    ]);
    return (store.daos.book.idOf(file.path)!, file.path);
  }

  test('依赖声明与 7 个方法', () {
    expect(reader.name, 'reader');
    expect(reader.dependsOn, containsAll(<String>['store', 'shelf']));
    expect(
      registry.all.map((m) => m.name).where((n) => n.startsWith('Reader.')).toSet(),
      {
        'Reader.GetChapters',
        'Reader.GetContent',
        'Reader.GetLocalFile',
        'Reader.GetLocalPage',
        'Reader.GetProgress',
        'Reader.SaveProgress',
        'Reader.SyncOutline',
      },
    );
  });

  test('GetLocalFile：本地书返回源文件路径，缺书报错', () async {
    final (id, path) = makeLocalBook();
    expect(await call('Reader.GetLocalFile', [id]), path);
    await expectLater(
      call('Reader.GetLocalFile', [999999]),
      throwsA(isA<LegadoException>()),
    );
  });

  test('目录按 index 排序，带 url / isVolume', () async {
    final (id, _) = makeLocalBook();
    final chapters = await callList('Reader.GetChapters', [id]);
    expect(chapters.map((c) => c['index']), [0, 1]);
    expect(chapters.first['title'], '第一章 起点');
    expect(chapters.first['isVolume'], isFalse);
    expect(chapters.first['url'], isA<String>());
  });

  test('本地 txt 正文：按字节偏移取、转义 HTML、带上下章', () async {
    final (id, _) = makeLocalBook();
    final first = await call('Reader.GetContent', [id, 0]) as Map<String, Object?>;
    expect(first['bookId'], id);
    expect(first['title'], '第一章 起点');
    expect(first['html'], contains('正文第一段 &amp; &lt;特殊字符&gt;'));
    expect(first['html'], contains('第二行'));
    expect(first['html'], isNot(contains('第一章 起点'))); // 标题行已剥掉
    expect(first['prevIndex'], -1);
    expect(first['nextIndex'], 1);
    expect(first['totalChapters'], 2);

    final last = await call('Reader.GetContent', [id, 1]) as Map<String, Object?>;
    expect(last['html'], contains('正文第二段'));
    expect(last['prevIndex'], 0);
    expect(last['nextIndex'], -1);
  });

  test('参数与缺失校验走统一错误码', () async {
    final (id, _) = makeLocalBook();
    await expectLater(
      call('Reader.GetContent', [id, -1]),
      throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.invalid)),
    );
    await expectLater(
      call('Reader.GetContent', [id, 99]),
      throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.notFound)),
    );
    await expectLater(
      call('Reader.GetChapters', [0]),
      throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.invalid)),
    );
  });

  test('进度读写委托给 Shelf，语义完全一致', () async {
    final (id, _) = makeLocalBook();
    expect((await call('Reader.GetProgress', [id]) as Map)['chapterIndex'], -1);

    await call('Reader.SaveProgress', [id, 1, '第二章 终点', 64, 42.5]);
    final viaReader = await call('Reader.GetProgress', [id]) as Map<String, Object?>;
    final viaShelf = await call('Shelf.GetProgress', [id]) as Map<String, Object?>;
    expect(viaReader, equals(viaShelf));
    expect(viaReader['chapterIndex'], 1);
    expect(viaReader['scrollPercent'], 42.5);
  });

  test('SyncOutline 整表替换目录，并同步章节数', () async {
    final (id, _) = makeLocalBook();
    await call('Reader.SyncOutline', [
      id,
      [
        {'index': 0, 'title': '卷一', 'url': 'vol://1', 'isVolume': true},
        {'index': 1, 'title': '第一章', 'url': 'ch://1', 'isVolume': false},
        {'index': 2, 'title': '第二章', 'url': 'ch://2', 'isVolume': false},
      ],
    ]);

    final chapters = await callList('Reader.GetChapters', [id]);
    expect(chapters.map((c) => c['title']), ['卷一', '第一章', '第二章']);
    expect(chapters.first['isVolume'], isTrue);
    expect(store.daos.book.getById(id)!.totalChapterNum, 3);

    await expectLater(
      call('Reader.SyncOutline', [id, const []]),
      throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.invalid)),
    );
  });

  test('本地漫画：GetLocalPage 逐页解压落盘并给出 mime', () async {
    final cbz = File('${home.path}/comic.cbz');
    cbz.writeAsBytesSync(
      buildZip({
        'p1.jpg': [0xFF, 0xD8, 0x01, 0x02],
        'p10.jpg': [0xFF, 0xD8, 0x03],
        'p2.png': [0x89, 0x50, 0x4E, 0x47],
        '__MACOSX/._p1.jpg': [0x00],
      }),
    );
    store.daos.book.insert(
      Book(
        bookUrl: cbz.path,
        name: '样例漫画',
        origin: BookType.localTag,
        type: BookType.local | BookType.image,
      ),
    );
    final id = store.daos.book.idOf(cbz.path)!;

    final first = await call('Reader.GetLocalPage', [id, 0]) as Map<String, Object?>;
    expect(first['index'], 0);
    // __MACOSX 垃圾条目被过滤，剩 p1/p2/p10 三页
    expect(first['pageCount'], 3);
    expect(first['name'], 'p1.jpg');
    expect(first['mime'], 'image/jpeg');
    final page = File(first['path']! as String);
    expect(page.existsSync(), isTrue);
    expect(page.readAsBytesSync(), [0xFF, 0xD8, 0x01, 0x02]);
    final sep = Platform.pathSeparator;
    expect(page.parent.path, endsWith('${sep}comic${sep}$id'));

    // 自然排序：p10 排在 p2 之后
    final png = await call('Reader.GetLocalPage', [id, 1]) as Map<String, Object?>;
    expect(png['name'], 'p2.png');
    expect(png['mime'], 'image/png');
    final tenth = await call('Reader.GetLocalPage', [id, 2]) as Map<String, Object?>;
    expect(tenth['name'], 'p10.jpg');
  });

  test('GetLocalPage：非漫画包 / 越界 / 网络书 / 负页码各自报错', () async {
    final (txtId, _) = makeLocalBook();
    await expectLater(
      call('Reader.GetLocalPage', [txtId, 0]),
      throwsA(
        isA<LegadoException>()
            .having((e) => e.code, 'code', ErrorCode.invalid)
            .having((e) => e.message, 'message', contains('不是漫画包')),
      ),
    );

    final cbz = File('${home.path}/one.cbz');
    cbz.writeAsBytesSync(buildZip({'1.jpg': [0xFF, 0xD8]}));
    store.daos.book.insert(
      Book(
        bookUrl: cbz.path,
        name: '一页漫画',
        origin: BookType.localTag,
        type: BookType.local | BookType.image,
      ),
    );
    final comicId = store.daos.book.idOf(cbz.path)!;
    await expectLater(
      call('Reader.GetLocalPage', [comicId, 1]),
      throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.notFound)),
    );
    await expectLater(
      call('Reader.GetLocalPage', [comicId, -1]),
      throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.invalid)),
    );

    store.daos.book.insert(
      Book(
        bookUrl: 'https://example.test/comic',
        name: '网络漫画',
        origin: 'https://example.test/s',
        type: BookType.image,
      ),
    );
    await expectLater(
      call('Reader.GetLocalPage', [
        store.daos.book.idOf('https://example.test/comic')!,
        0,
      ]),
      throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.invalid)),
    );
  });

  test('网络书正文明确 NOT_IMPLEMENTED，不返回空白页', () async {
    store.daos.book.insert(
      Book(
        bookUrl: 'https://example.test/book',
        name: '网络书',
        origin: 'https://example.test/s',
        type: BookType.text,
      ),
    );
    final id = store.daos.book.idOf('https://example.test/book')!;
    store.daos.chapter.insert(
      BookChapter(
        url: 'https://example.test/book/1',
        bookUrl: 'https://example.test/book',
        index: 0,
        title: '第一章',
      ),
    );

    await expectLater(
      call('Reader.GetContent', [id, 0]),
      throwsA(
        isA<LegadoException>()
            .having((e) => e.code, 'code', ErrorCode.notImplemented),
      ),
    );
  });
}
