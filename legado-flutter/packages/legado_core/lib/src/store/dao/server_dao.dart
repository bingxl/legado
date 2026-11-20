import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `servers` 表访问。
class ServerDao {
  ServerDao(this._db);

  final Database _db;

  static const String _table = Server.tableServers;

  static const String _insertSql =
      'INSERT OR REPLACE INTO `$_table` (`id`, `name`, `type`, `config`, `sortNumber`) '
      'VALUES (?, ?, ?, ?, ?)';

  List<Server> get all => _db
      .select('select * from `$_table` order by sortNumber')
      .map((r) => Server.fromRow(r))
      .toList();

  Server? get(int id) {
    final rows = _db.select('select * from `$_table` where id = ?', [id]);
    return rows.isEmpty ? null : Server.fromRow(rows.first);
  }

  void insert(Server server) => _db.execute(
        _insertSql,
        [server.id, server.name, server.type, server.config, server.sortNumber],
      );

  void update(Server server) => _db.execute(
        'update `$_table` set name = ?, type = ?, config = ?, sortNumber = ? '
        'where id = ?',
        [server.name, server.type, server.config, server.sortNumber, server.id],
      );

  void delete(Server server) => deleteById(server.id);

  void deleteById(int id) => _db.execute('delete from `$_table` where id = ?', [id]);

  void deleteDefault() => _db.execute('delete from `$_table` where id < 0');
}
