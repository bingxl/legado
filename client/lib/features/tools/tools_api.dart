import '../../core/bridge/legado_client.dart';

/// 「我的」tab 与其下三个工具页（缓存 / 书签 / 阅读记录）的控制面封装。
///
/// 为什么不写进 `core/bridge/api.dart`：
/// 那个文件是并行开发的共享区，抬头注释明确要求各 feature 自带常量，
/// 多人同时往一份常量表追加方法名必然冲突。这里只放本模块用到的方法。
///
/// 参数全部是**位置参数**，顺序与 `core/modules/*/module.go` 里的
/// `kernel.Sig(...)` 一致：
///   Cache.Delete(bookId, [chapterIndexes])   ← 第二个参数本身是数组
///   Bookmark.List(bookId, limit)             ← bookId=0 表示全部
///   Record.Clear(beforeDays)                 ← 0 表示全部清空
class ToolsApi {
  ToolsApi._();

  static LegadoClient get _c => LegadoClient.instance;

  // ── 系统 ────────────────────────────────────────────────

  /// {arch, go, platform, version}
  static Future<Map<String, dynamic>> systemInfo() async =>
      _map(await _c.call('System.Info'));

  // ── 缓存 ────────────────────────────────────────────────

  /// {books, chapters, size, running}
  static Future<Map<String, dynamic>> cacheStats() async =>
      _map(await _c.call('Cache.Stats'));

  /// 每本书带 totalChapters / cachedChapters / size / job（可为 null）。
  static Future<List<Map<String, dynamic>>> cacheBooks() =>
      _c.callList('Cache.Books');

  /// 已缓存章节明细：{index, title, size, updatedAt}
  static Future<List<Map<String, dynamic>>> cacheChapters(int bookId) =>
      _c.callList('Cache.Chapters', [bookId]);

  /// 删除若干章；indexes 为空时 core 什么也不做，故这里直接短路。
  static Future<void> cacheDelete(int bookId, List<int> indexes) {
    if (indexes.isEmpty) return Future<void>.value();
    return _c.call('Cache.Delete', [bookId, indexes]);
  }

  static Future<void> cachePurgeBook(int bookId) =>
      _c.call('Cache.PurgeBook', [bookId]);

  static Future<void> cacheClear() => _c.call('Cache.Clear');

  static Future<void> cacheCancel(int bookId) =>
      _c.call('Cache.Cancel', [bookId]);

  // ── 书签 ────────────────────────────────────────────────

  /// bookId=0 表示全部，按创建时间倒序。
  static Future<List<Map<String, dynamic>>> bookmarks(int bookId, int limit) =>
      _c.callList('Bookmark.List', [bookId, limit]);

  static Future<void> bookmarkRemove(int id) =>
      _c.call('Bookmark.Remove', [id]);

  static Future<void> bookmarkUpdateNote(int id, String note) =>
      _c.call('Bookmark.UpdateNote', [id, note]);

  // ── 阅读记录 ────────────────────────────────────────────

  /// {days, books, records}
  static Future<Map<String, dynamic>> recordStats() async =>
      _map(await _c.call('Record.Stats'));

  /// 按时间倒序分页；offset/limit 语义与 RSS 列表一致。
  static Future<List<Map<String, dynamic>>> records(int offset, int limit) =>
      _c.callList('Record.List', [offset, limit]);

  /// 清理记录，返回删除条数；beforeDays=0 表示全部。
  static Future<int> recordClear(int beforeDays) async {
    final data = await _c.call('Record.Clear', [beforeDays]);
    return toolsInt(data);
  }

  /// 书架书籍列表。stats 里「书架」那个数字要的是本数，
  /// 但只有 Shelf 域知道分组切分，所以取全量（groupId=0）后数长度。
  static Future<List<Map<String, dynamic>>> shelfBooks() =>
      _c.callList('Shelf.ListBooks', [0]);

  static Map<String, dynamic> _map(dynamic data) {
    if (data is Map) return data.cast<String, dynamic>();
    return <String, dynamic>{};
  }
}

/// 从 dto 里安全取整数：后端可能给 int / double / 字符串，缺失时为 0。
int toolsInt(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

/// 安全取字符串，null 视为空串，省掉满屏的 `?? ''`。
String toolsStr(dynamic value) => value == null ? '' : '$value';
