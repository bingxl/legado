import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';

import 'package:legado_core/src/core.dart';
import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/format/format.dart';
import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/library/library_module.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// Library 域接线测试：真实落盘 txt → 解析目录 → 入库 → BookBrief 回执，
/// 覆盖重复导入更新、失败隔离与导出。
void main() {
  late Directory home;
  late StoreModule store;
  late ShelfModule shelf;
  late LibraryModule library;
  late Registry registry;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-library-module');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    shelf = ShelfModule();
    shelf.register(registry, ctx());
    library = LibraryModule();
    library.register(registry, ctx());
  });

  tearDown(() async {
    await library.close();
    await shelf.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<Map<String, Object?>> callMap(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as Map).cast<String, Object?>();

  File makeTxt(String name, String text) {
    final file = File('${home.path}${Platform.pathSeparator}$name');
    file.writeAsStringSync(text, encoding: utf8);
    return file;
  }

  const sample = '第一章 开端\n正文第一段。\n第二行。\n'
      '第二章 发展\n更多正文。\n'
      '第三章 结局\n完。\n';

  test('依赖与方法注册', () {
    expect(library.name, 'library');
    expect(library.dependsOn, containsAll(<String>['store', 'shelf']));
    expect(
      registry.all.map((m) => m.name),
      containsAll(<String>['Library.ImportLocalFiles', 'Library.ExportBook']),
    );
  });

  test('导入 txt：目录落库、回执是 BookBrief、书架可见', () async {
    final file = makeTxt('sample.txt', sample);
    final expectedChapters = (await BookParser.parse(
      Uint8List.fromList(utf8.encode(sample)),
      fileName: 'sample.txt',
    )).chapters.length;
    final result = await callMap('Library.ImportLocalFiles', [
      [file.path],
      0,
    ]);
    final imported = (result['imported'] as List).cast<Map<String, Object?>>();
    expect(result['failed'], isEmpty);
    expect(imported.length, 1);
    expect(imported.single['kind'], 'txt');
    expect(imported.single['formatLabel'], '文本');
    expect(imported.single['totalChapters'], expectedChapters);
    expect(imported.single['inShelf'], isTrue);
    expect(imported.single['fileMissing'], isFalse);

    final id = imported.single['id'] as int;
    expect(store.daos.chapter.getChapterCount(file.path), expectedChapters);
    final chapters = store.daos.chapter.getChapterList(file.path);
    expect(chapters.first.title, contains('第一章'));
    expect(chapters.first.start, isA<int>());

    final brief = await call('Shelf.GetBook', [id]) as Map<String, Object?>;
    expect(brief['name'], isNotEmpty);
  });

  test('导入 PDF：能入库、每 10 页分段、type 含 text 位', () async {
    final pdfBytes = utf8.encode(
      '%PDF-1.7\n'
      '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
      '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 23>>endobj\n'
      '3 0 obj<</Type/Page/Parent 2 0 R>>endobj\n'
      'trailer<</Root 1 0 R>>\n%%EOF',
    );
    final file = File('${home.path}${Platform.pathSeparator}scan.pdf');
    file.writeAsBytesSync(pdfBytes);
    final result = await callMap('Library.ImportLocalFiles', [
      [file.path],
      0,
    ]);
    expect(result['failed'], isEmpty);
    final imported = (result['imported'] as List).cast<Map<String, Object?>>();
    expect(imported.single['kind'], 'pdf');
    expect(imported.single['formatLabel'], 'PDF');
    expect(imported.single['totalChapters'], 3);

    final book = store.daos.book.getBook(file.path);
    expect(book, isNotNull);
    expect(book!.type & BookType.text, isNot(0));
    expect(book.type & BookType.local, isNot(0));
    final chapters = store.daos.chapter.getChapterList(file.path);
    expect(chapters.first.start, 0);
    expect(chapters.first.end, 10);
    expect(chapters.last.end, 23);
  });

  test('同路径重复导入是更新，不产生第二条', () async {
    final file = makeTxt('again.txt', sample);
    final expected = (await BookParser.parse(
      Uint8List.fromList(utf8.encode(sample)),
      fileName: 'again.txt',
    )).chapters.length;
    await call('Library.ImportLocalFiles', [
      [file.path],
      0,
    ]);
    await call('Library.ImportLocalFiles', [
      [file.path],
      0,
    ]);
    expect(store.daos.book.all.length, 1);
    expect(store.daos.chapter.getChapterCount(file.path), expected);
  });

  test('失败逐条隔离：不存在的文件只记 failed', () async {
    final result = await callMap('Library.ImportLocalFiles', [
      ['${home.path}${Platform.pathSeparator}missing.txt'],
      0,
    ]);
    expect(result['imported'], isEmpty);
    final failed = (result['failed'] as List).cast<Map<String, Object?>>();
    expect(failed.length, 1);
    expect(failed.single['path'], contains('missing.txt'));
    expect(failed.single['reason'], contains('不存在'));
  });

  test('导出 txt 到指定路径；不支持的格式抛 NOT_IMPLEMENTED', () async {
    final file = makeTxt('export.txt', sample);
    final imported = (await callMap('Library.ImportLocalFiles', [
      [file.path],
      0,
    ]))['imported'] as List;
    final id = (imported.first as Map)['id'] as int;

    final dest = '${home.path}${Platform.pathSeparator}out.txt';
    final result = await callMap('Library.ExportBook', [id, 'txt', dest]);
    expect(result['path'], dest);
    expect(result['format'], 'txt');
    expect(result['size'], File(dest).lengthSync());
    expect(File(dest).readAsStringSync(), sample);

    await expectLater(
      call('Library.ExportBook', [id, 'epub', dest]),
      throwsA(isA<LegadoException>()
          .having((e) => e.code, 'code', ErrorCode.notImplemented)),
    );
  });

  test('经 LegadoCore 全链路能调到导入', () async {
    await LegadoCore.instance.init(homeDir: home.path, version: 'test');
    try {
      expect(LegadoCore.instance.methods().map((m) => m.name),
          contains('Library.ImportLocalFiles'));
      final file = makeTxt('core.txt', sample);
      final result = await LegadoCore.instance.call('Library.ImportLocalFiles', [
        [file.path],
        0,
      ]) as Map<String, Object?>;
      expect((result['imported'] as List).length, 1);
    } finally {
      await LegadoCore.instance.close();
    }
  });
}
