import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';
import 'schema.dart';

/// 已打开的数据库。
///
/// 只做三件事：打开连接时设好 PRAGMA、按 `user_version` 顺序跑迁移、关连接。
/// 不做连接池 —— 桌面/移动端都是单进程单写者，WAL + busy_timeout 已经够用，
/// 引入池反而会在「事务里再取一个连接」时把自己锁死。
class LegadoDatabase {
  LegadoDatabase._(this.db, this.path);

  /// 打开（或创建）磁盘数据库。
  static Future<LegadoDatabase> open(
    String path, {
    List<Migration>? migrations,
  }) async {
    final raw = sqlite3.open(path);
    final database = LegadoDatabase._(raw, path);
    try {
      database._configure();
      database.migrate(migrations ?? defaultMigrations);
    } catch (_) {
      raw.close();
      rethrow;
    }
    return database;
  }

  /// 内存库：测试与「一次性的导入校验」使用。
  ///
  /// 内存库不支持 WAL，PRAGMA 会自动降级为 memory，不影响语义。
  static LegadoDatabase inMemory({List<Migration>? migrations}) {
    final raw = sqlite3.openInMemory();
    final database = LegadoDatabase._(raw, ':memory:');
    try {
      database._configure();
      database.migrate(migrations ?? defaultMigrations);
    } catch (_) {
      raw.close();
      rethrow;
    }
    return database;
  }

  final Database db;

  /// 数据库文件路径；内存库为 `:memory:`。
  final String path;

  void _configure() {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = 5000');
    // Android 版靠系统 ICU 注册 `LOCALIZED` 排序规则；纯 Dart 里没有，
    // 而 BookmarkDao / ReadRecordDao 的 SQL 里带着 `collate localized`，
    // 不注册会在执行时报「no such collation sequence」，且只在查列表时才炸。
    db.createCollation(
      name: 'localized',
      function: (a, b) => (a ?? '').compareTo(b ?? ''),
    );
  }

  /// 当前 schema 版本。
  int get version => db.userVersion;

  /// 按版本号升序执行未应用的迁移。
  ///
  /// 每一步单独一个事务：中途失败时，已完成的版本保持有效，
  /// 下次启动从断点继续，而不是「全部回滚后每次启动都失败」。
  void migrate(List<Migration> migrations) {
    final ordered = [...migrations]..sort((a, b) => a.version.compareTo(b.version));
    for (final migration in ordered) {
      if (migration.version <= db.userVersion) continue;
      db.execute('BEGIN IMMEDIATE');
      try {
        migration.up(db);
        db.userVersion = migration.version;
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  /// 实际存在的表名（排除 sqlite 内部表）。
  List<String> tableNames() {
    final rows = db.select(
      "select name from sqlite_master where type = 'table' "
      "and name not like 'sqlite_%' order by name",
    );
    return [for (final row in rows) row['name'] as String];
  }

  /// 表名 → 行数，供 `System.Database` 与测试巡检。
  Map<String, int> tableRowCounts() {
    final result = <String, int>{};
    for (final name in tableNames()) {
      final row = db.select('select count(*) as c from `$name`').first;
      result[name] = row['c'] as int;
    }
    return result;
  }

  void close() => db.close();
}

/// 在一个事务里执行 [action]，异常时回滚并原样抛出。
///
/// `sqlite3` 包没有内置事务封装；DAO 里凡是「多行写入」都必须走它，
/// 否则几千章逐条 INSERT 会触发几千次 fsync，实际表现是「导入目录卡死」。
T runInTransaction<T>(Database db, T Function() action) {
  db.execute('BEGIN IMMEDIATE');
  try {
    final result = action();
    db.execute('COMMIT');
    return result;
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}
