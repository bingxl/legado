import 'package:sqlite3/sqlite3.dart';

/// 一次 schema 升级。
///
/// `version` 是升级**后**的版本号（迁移到 2 就写 2），
/// 与 Android 侧 `Migration(from, to)` 的双版本号不同：
/// 单版本号足以表达顺序，且少一个「from 写错但没人发现」的坑。
class Migration {
  const Migration(this.version, this.up);

  final int version;
  final void Function(Database db) up;
}
