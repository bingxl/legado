import 'package:legado_core/src/store/database.dart';
import 'package:legado_core/src/store/dao/settings_dao.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'store_test_support.dart';

void main() {
  late LegadoDatabase database;
  late SettingsDao dao;

  setUp(() {
    database = openTestDb();
    dao = SettingsDao(database.db);
  });

  tearDown(() => database.close());

  group('SettingsDao', () {
    test('put / get / getAll / count 基本读写', () async {
      await dao.put('theme', 'dark');
      await dao.put('fontSize', '18');

      expect(dao.get('theme'), 'dark');
      expect(dao.get('missing'), isNull);
      expect(dao.getAll(), {'theme': 'dark', 'fontSize': '18'});
      expect(dao.count(), 2);
    });

    test('重复 put 覆盖旧值而不是新增行', () async {
      await dao.put('k', 'v1');
      await dao.put('k', 'v2');
      expect(dao.get('k'), 'v2');
      expect(dao.count(), 1);
    });

    test('put(key, null) 等价删除', () async {
      await dao.put('k', 'v');
      await dao.put('k', null);
      expect(dao.get('k'), isNull);
      expect(dao.count(), 0);
    });

    test('putAll 单事务：中途失败整体回滚', () async {
      database.db.execute('''
        CREATE TRIGGER fail_on_bad BEFORE INSERT ON app_settings
        WHEN NEW.`key` = 'bad'
        BEGIN SELECT RAISE(ABORT, 'boom'); END;
      ''');

      await expectLater(
        dao.putAll({'a': '1', 'bad': 'x', 'c': '3'}),
        throwsA(isA<SqliteException>()),
      );
      expect(dao.get('a'), isNull, reason: 'a 在 bad 之前写入，必须被回滚');
      expect(dao.get('c'), isNull);
      expect(dao.count(), 0);
    });

    test('putAll 支持同时 upsert 与删除', () async {
      await dao.putAll({'a': '1', 'b': '2'});
      await dao.putAll({'a': '9', 'b': null, 'c': '3'});
      expect(dao.getAll(), {'a': '9', 'c': '3'});
    });

    test('removeAll 指定键只删命中项', () async {
      await dao.putAll({'a': '1', 'b': '2', 'c': '3'});
      await dao.removeAll(['a', 'c', '不存在']);
      expect(dao.getAll(), {'b': '2'});
    });

    test('removeAll(空列表) 清空全表', () async {
      await dao.putAll({'a': '1', 'b': '2'});
      await dao.removeAll(const []);
      expect(dao.count(), 0);
      expect(dao.getAll(), isEmpty);
    });

    test('中文与 emoji 值往返不变', () async {
      const value = '夜间模式🌙 字体："宋体"，行距 1.5';
      await dao.put('中文键', value);
      expect(dao.get('中文键'), value);

      final exported = dao.getAll();
      expect(exported['中文键'], value);
    });

    test('getAll 跳过 value 为 null 的旧行（直接 SQL 插入的脏数据）', () async {
      database.db.execute(
        "INSERT INTO app_settings (`key`, `value`) VALUES ('raw-null', NULL)",
      );
      await dao.put('ok', 'v');
      expect(dao.getAll(), {'ok': 'v'});
      expect(dao.count(), 2, reason: 'count 统计物理行，getAll 只返回有值行');
    });

    test('未写过的库 getAll 为空、count 为 0', () {
      expect(dao.getAll(), isEmpty);
      expect(dao.count(), 0);
    });
  });
}
