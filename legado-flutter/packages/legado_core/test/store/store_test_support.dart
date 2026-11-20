import 'package:legado_core/src/store/database.dart';

/// 打开一个跑完默认迁移的内存库。
LegadoDatabase openTestDb() => LegadoDatabase.inMemory();

/// 用 `toRow()` 的结果直接插一行，返回从库里读回来的行。
///
/// 刻意不复用 DAO：round-trip 测的是实体与表的映射，DAO 有 bug 时不应该把
/// 实体映射的问题一起掩盖掉。
Map<String, Object?> insertAndRead(
  LegadoDatabase database,
  String table,
  Map<String, Object?> row,
) {
  final keys = row.keys.toList();
  final columns = keys.map((k) => '`$k`').join(', ');
  final placeholders = List.filled(keys.length, '?').join(', ');
  database.db.execute(
    'INSERT OR REPLACE INTO `$table` ($columns) VALUES ($placeholders)',
    [for (final key in keys) row[key]],
  );
  // 必须按 last_insert_rowid 取，不能 `.first`：库里往往还有别的行，
  // 取第一行会返回错的实体，表现为「某个字段莫名不对」的假失败。
  return database.db
      .select('SELECT * FROM `$table` WHERE rowid = ?', [database.db.lastInsertRowId])
      .first;
}
