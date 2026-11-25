import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/api.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/shelf/shelf_api.dart';
import 'package:path/path.dart' as p;

/// 本地导入的文件名处理：书名由文件名推出（TXT/漫画解析器在文件里没有书名
/// 时都用文件名兜底），所以导入时**不能**把中文洗成下划线。
///
/// 旧实现 `[^\w.\-] → _`（Dart 的 `\w` 只含 ASCII）会把《我的小说.txt》存成
/// `________.txt`，书架上就显示一串下划线；时间戳前缀还让每次重导都多一本书。
void main() {
  late Directory home;

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('legado-import-name');
    await LegadoClient.connect(homeDir: home.path);
  });

  tearDownAll(() async {
    if (LegadoClient.isReady) await LegadoClient.instance.dispose();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  /// 正文够长，避免编码探测把中文样本误判成 GBK 而分章塌成 1 章。
  String bookText(int chapters) {
    const body = '　　天色渐暗，风从山脊上压下来，吹得满林的松针一起响。'
        '他站在崖边，把信纸折了两折，塞进怀里，继续向前走去。';
    final buf = StringBuffer();
    for (var i = 1; i <= chapters; i++) {
      buf
        ..writeln('第$i章 测试章节')
        ..writeln(body)
        ..writeln();
    }
    return buf.toString();
  }

  Future<Map<String, dynamic>> importOne(String name, {int chapters = 2}) async {
    final result = await ShelfApi.importLocalBytes(
      [
        (name: name, bytes: utf8.encode(bookText(chapters))),
      ],
      0,
      homeDir: home.path,
    );
    final imported = (result['imported'] as List?) ?? const <Object>[];
    expect(imported, isNotEmpty, reason: '导入失败: ${result['failed']}');
    return (imported.first as Map).cast<String, dynamic>();
  }

  /// 书架 brief 不带 bookUrl（落盘路径），书名/路径要另取详情。
  Future<String> bookUrlOf(Map<String, dynamic> brief) async {
    final book = await LegadoClient.instance.call(
      Api.shelfGetBook,
      [(brief['id'] as num).toInt()],
    );
    return '${(book as Map)['bookUrl'] ?? ''}';
  }

  test('中文文件名导入后书名保留中文，不再变成下划线', () async {
    final brief = await importOne('我的小说.txt');
    expect(brief['name'], '我的小说');
    // 落盘文件名与书名一致，扩展名保留（按扩展名判格式）。
    expect(p.basename(await bookUrlOf(brief)), '我的小说.txt');
  });

  test('同名再导入是更新：同一本书、目录跟着换，不多出副本', () async {
    final first = await importOne('重导测试.txt', chapters: 2);
    final id = (first['id'] as num).toInt();
    expect(first['totalChapters'], 2);

    final second = await importOne('重导测试.txt', chapters: 3);
    expect((second['id'] as num).toInt(), id, reason: '同名文件应更新同一本书');
    expect(second['totalChapters'], 3);
    expect(second['name'], '重导测试');

    final books = await LegadoClient.instance.callList(Api.shelfListBooks, [0]);
    final same = books.where((b) => b['name'] == '重导测试').toList();
    expect(same.length, 1);
  });

  test('同一次批量里的重名文件各自成书，不互相覆盖', () async {
    final result = await ShelfApi.importLocalBytes(
      [
        (name: '重复.txt', bytes: utf8.encode(bookText(1))),
        (name: '重复.txt', bytes: utf8.encode(bookText(2))),
      ],
      0,
      homeDir: home.path,
    );
    final imported = ((result['imported'] as List?) ?? const <Object>[])
        .map((m) => (m as Map).cast<String, dynamic>())
        .toList();
    expect(imported.length, 2);
    expect(imported.map((m) => m['name']).toSet(), {'重复', '重复 (2)'});
  });

  test('只替换文件系统不接受的字符，其余原样保留', () async {
    final brief = await importOne('第1 卷:起点?.txt');
    expect(p.basename(await bookUrlOf(brief)), '第1 卷_起点_.txt');
  });

  test('重新导入不会抹掉用户改过的书名与作者', () async {
    final first = await importOne('原名.txt', chapters: 2);
    final id = (first['id'] as num).toInt();
    await ShelfApi.saveBook(
      bookId: id,
      name: '自定义书名',
      author: '自定义作者',
      coverUrl: '',
      intro: '',
      groupId: -1,
    );

    // 同名文件改了内容再导入：目录要更新，书名/作者得留住（原版
    // LocalBook.importFile 对已存在的书不碰 name/author）。
    final again = await importOne('原名.txt', chapters: 3);
    expect((again['id'] as num).toInt(), id);
    expect(again['name'], '自定义书名');
    expect(again['author'], '自定义作者');
    expect(again['totalChapters'], 3);
  });
}
