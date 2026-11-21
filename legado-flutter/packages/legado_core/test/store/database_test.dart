import 'dart:io';

import 'package:legado_core/src/store/database.dart';
import 'package:legado_core/src/store/migration.dart';
import 'package:legado_core/src/store/schema.dart';
import 'package:test/test.dart';

import 'store_test_support.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('legado-store-test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('LegadoDatabase 迁移', () {
    test('新库跑完默认迁移后 user_version 等于 schemaVersion', () {
      final db = openTestDb();
      addTearDown(db.close);
      expect(db.version, schemaVersion);
    });

    test('默认迁移建出全部表，且没有遗漏', () {
      final db = openTestDb();
      addTearDown(db.close);
      expect(db.tableNames(), containsAll(dataTableNames));
      // 视图不在 tableNames 里，单独确认它存在。
      final views = db.db
          .select("select name from sqlite_master where type = 'view'")
          .map((r) => r['name'])
          .toList();
      expect(views, contains('book_sources_part'));
    });

    test('默认迁移没有多建表（防止漏改名后的孤儿表）', () {
      final db = openTestDb();
      addTearDown(db.close);
      expect(db.tableNames().toSet(), dataTableNames.toSet());
    });

    test('重复 migrate 幂等：不重复执行、不报错', () {
      final db = openTestDb();
      addTearDown(db.close);
      expect(() => db.migrate(defaultMigrations), returnsNormally);
      expect(db.version, schemaVersion);
    });

    test('磁盘库关闭后重新打开不重复建表', () async {
      final path = '${tempDir.path}/legado.db';
      final first = await LegadoDatabase.open(path);
      expect(first.version, schemaVersion);
      first.close();

      final second = await LegadoDatabase.open(path);
      addTearDown(second.close);
      expect(second.version, schemaVersion);
      expect(second.tableNames().toSet(), dataTableNames.toSet());
    });

    test('迁移按版本号升序执行，每步单独提交', () async {
      final path = '${tempDir.path}/ordered.db';
      // 自定义迁移的版本号必须避开默认链的最大版本：
      // `migrate` 会跳过 `version <= user_version` 的步骤，重复版本号会被静默吃掉。
      final db = await LegadoDatabase.open(
        path,
        migrations: [
          ...defaultMigrations,
          Migration(4, (raw) => raw.execute('CREATE TABLE step_three (id INTEGER)')),
          Migration(3, (raw) => raw.execute('CREATE TABLE step_two (id INTEGER)')),
        ],
      );
      addTearDown(db.close);

      expect(db.version, 4);
      expect(db.tableNames(), containsAll(['step_two', 'step_three']));
    });

    test('中间某个迁移失败时回滚该步，已完成的版本保留', () async {
      final path = '${tempDir.path}/broken.db';
      final broken = [
        ...defaultMigrations,
        Migration(3, (raw) {
          raw.execute('CREATE TABLE probe_rollback (id INTEGER)');
          throw StateError('故意失败');
        }),
      ];

      await expectLater(
        LegadoDatabase.open(path, migrations: broken),
        throwsA(isA<StateError>()),
      );

      // 用正常迁移链重新打开：v1 的内容还在，失败那步的建表被回滚。
      final reopened = await LegadoDatabase.open(path);
      addTearDown(reopened.close);
      expect(reopened.version, schemaVersion);
      expect(reopened.tableNames(), isNot(contains('probe_rollback')));
      expect(reopened.tableNames(), contains('books'));
    });

    test('外键开启：删书级联删章节', () {
      final db = openTestDb();
      addTearDown(db.close);
      final pragma =
          db.db.select('PRAGMA foreign_keys').first.values.first;
      expect(pragma, 1);

      db.db.execute(
        "INSERT INTO books (bookUrl, name, author) VALUES ('u1', '书', '作者')",
      );
      db.db.execute(
        "INSERT INTO chapters (url, title, isVolume, baseUrl, bookUrl, `index`, "
        "isVip, isPay) VALUES ('c1', '第一章', 0, '', 'u1', 0, 0, 0)",
      );
      expect(
        db.db.select('select count(*) as c from chapters').first['c'],
        1,
      );

      db.db.execute("DELETE FROM books WHERE bookUrl = 'u1'");
      expect(
        db.db.select('select count(*) as c from chapters').first['c'],
        0,
      );
    });

    test('tableRowCounts 返回每张表的行数', () {
      final db = openTestDb();
      addTearDown(db.close);
      db.db.execute(
        "INSERT INTO search_keywords (word, usage, lastUseTime) VALUES ('x', 1, 0)",
      );
      final counts = db.tableRowCounts();
      expect(counts['search_keywords'], 1);
      expect(counts['books'], 0);
      expect(counts.keys.toSet(), dataTableNames.toSet());
    });
  });
}
