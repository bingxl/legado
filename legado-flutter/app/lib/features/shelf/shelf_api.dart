/// 书架「添加书籍」与 WebDAV 相关的 core 调用封装。
///
/// 各 feature 自带方法名常量（共享 Api 文件不允许追加，见 api.dart 注释）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';

class ShelfApi {
  ShelfApi._();

  /// 编辑书籍信息（书名/作者/封面/简介/分组）。
  static const saveBookMethod = 'Shelf.SaveBook';

  /// 换源（core 负责重建目录与迁移进度）。
  static const changeSourceMethod = 'Source.ChangeSource';

  // 分组管理 / 书架管理 / 目录刷新
  static const createGroupMethod = 'Shelf.CreateGroup';
  static const updateGroupMethod = 'Shelf.UpdateGroup';
  static const deleteGroupMethod = 'Shelf.DeleteGroup';
  static const setCanUpdateMethod = 'Shelf.SetCanUpdate';
  static const moveToGroupsMethod = 'Shelf.MoveToGroups';
  static const addToGroupsMethod = 'Shelf.AddToGroups';
  static const deleteBooksMethod = 'Shelf.DeleteBooks';
  static const exportBookshelfMethod = 'Shelf.ExportBookshelf';
  static const refreshTocMethod = 'Source.RefreshToc';
  static const refreshBookMethod = 'Source.RefreshBook';
  static const batchChangeSourceMethod = 'Source.BatchChangeSource';
  static const importBookshelfMethod = 'Source.ImportBookshelf';
  static const purgeBookCacheMethod = 'Cache.PurgeBook';

  // 本地书籍
  static const importLocalFiles = 'Library.ImportLocalFiles';
  // 网址加书
  static const addBookByUrl = 'Source.AddBookByUrl';
  // WebDAV
  static const webdavGetConfigMethod = 'WebDAV.GetConfig';
  static const webdavSaveConfigMethod = 'WebDAV.SaveConfig';
  static const webdavTestMethod = 'WebDAV.Test';
  static const webdavListMethod = 'WebDAV.List';
  static const webdavScanBooksMethod = 'WebDAV.ScanBooks';
  static const webdavDeleteMethod = 'WebDAV.Delete';
  static const webdavStartImportMethod = 'WebDAV.StartBookImport';
  static const webdavImportStatusMethod = 'WebDAV.ImportStatus';
  static const webdavCancelImportMethod = 'WebDAV.CancelBookImport';
  static const webdavUploadBackupMethod = 'WebDAV.UploadBackup';
  static const webdavBackupStatusMethod = 'WebDAV.BackupStatus';
  static const webdavDownloadBackupMethod = 'WebDAV.DownloadBackup';
  // 导出
  static const exportFormatsMethod = 'Export.Formats';
  static const exportBookMethod = 'Export.Book';

  static LegadoClient get _c => LegadoClient.instance;

  /// 本地文件导入：把字节写到应用私有目录（Android content:// 没有可读 path），
  /// 再把真实路径交给 core 的 Library.ImportLocalFiles。
  ///
  /// [files] 每项含显示名与字节；[homeDir] 来自 [LegadoClient.homeDir]。
  static Future<Map<String, dynamic>> importLocalBytes(
    List<({String name, List<int> bytes})> files,
    int groupId, {
    required String homeDir,
  }) async {
    final dir = Directory(p.join(homeDir, 'imports'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final paths = <String>[];
    // 只用于**本次批量**内去重：同名的两个文件不能落到同一路径，否则后一个
    // 覆盖前一个，库里只剩一本书。
    final usedNames = <String>{};
    for (final f in files) {
      final safeName = _uniqueImportName(_safeImportName(f.name), usedNames);
      final path = p.join(dir.path, safeName);
      await File(path).writeAsBytes(f.bytes, flush: true);
      paths.add(path);
    }
    final result = await _c.call(importLocalFiles, [paths, groupId]);
    return (result as Map).cast<String, dynamic>();
  }

  /// 导入文件名 → 可落盘的文件名。
  ///
  /// **必须保留中文等 Unicode 字符**：书名是从文件名推出来的（内核 TXT/漫画
  /// 解析器在文件里没有书名时都用文件名兜底），旧实现 `[^\w.\-] → _` 因为
  /// Dart 的 `\w` 只匹配 ASCII，把《我的小说.txt》变成了 `________.txt`，
  /// 书架上就显示一串下划线。这里只替换文件系统真正不接受的字符：
  /// 路径分隔符、Windows 保留字符、控制字符（Android/Windows 都安全）。
  ///
  /// 时间戳前缀也去掉了：改成**同名即覆盖**。这是原版 `saveBookFile` 的语义
  /// —— 内核按 `bookUrl`（= 落盘路径）查重，同名复用路径才会走「更新已有
  /// 书籍」；带时间戳的话每次导入都是新路径，书架只会多出一本同名副本，
  /// 用户改过 txt 再导入也拿不到更新后的目录与正文。
  static String _safeImportName(String name) {
    final base = p.basename(name).trim();
    var safe = base.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    // Windows 不允许文件名以点或空格结尾（Android 允许，但没必要区别对待）。
    safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty || safe == '.' || safe == '..') return 'book';
    return safe;
  }

  /// 本次批量内重名时依次加 ` (2)`、` (3)`，保留扩展名。
  static String _uniqueImportName(String name, Set<String> used) {
    final ext = p.extension(name);
    final stem = ext.isEmpty ? name : name.substring(0, name.length - ext.length);
    var candidate = name;
    var n = 2;
    // 用 lower-case 判重：Windows 文件系统不区分大小写。
    while (!used.add(candidate.toLowerCase())) {
      candidate = '$stem ($n)$ext';
      n++;
    }
    return candidate;
  }

  /// 按网址加书（多行）。
  static Future<Map<String, dynamic>> addByUrls(String urls, int groupId) async {
    final result = await _c.call(addBookByUrl, [urls, groupId]);
    return (result as Map).cast<String, dynamic>();
  }

  static Future<Map<String, dynamic>> webdavConfig() async =>
      ((await _c.call(webdavGetConfigMethod)) as Map).cast<String, dynamic>();

  static Future<Map<String, dynamic>> saveWebdavConfig({
    required String url,
    required String username,
    required String password,
    required String rootPath,
    required bool autoSync,
  }) async =>
      ((await _c.call(webdavSaveConfigMethod, [url, username, password, rootPath, autoSync])) as Map)
          .cast<String, dynamic>();

  static Future<void> webdavTest() => _c.call(webdavTestMethod);

  static Future<List<Map<String, dynamic>>> webdavList(String relPath) async {
    final data = await _c.call(webdavListMethod, [relPath]);
    if (data == null) return const [];
    return (data as List).cast<Map<String, dynamic>>();
  }

  static Future<List<Map<String, dynamic>>> webdavScan(String relPath) async {
    final data = await _c.call(webdavScanBooksMethod, [relPath]);
    if (data == null) return const [];
    return (data as List).cast<Map<String, dynamic>>();
  }

  static Future<void> webdavDelete(String relPath) => _c.call(webdavDeleteMethod, [relPath]);

  static Future<Map<String, dynamic>> startImport(List<String> relPaths, int groupId) async =>
      ((await _c.call(webdavStartImportMethod, [relPaths, groupId])) as Map).cast<String, dynamic>();

  static Future<Map<String, dynamic>> importStatus() async =>
      ((await _c.call(webdavImportStatusMethod)) as Map).cast<String, dynamic>();

  static Future<void> cancelImport() => _c.call(webdavCancelImportMethod);

  static Future<Map<String, dynamic>> uploadBackup() async =>
      ((await _c.call(webdavUploadBackupMethod)) as Map).cast<String, dynamic>();

  static Future<Map<String, dynamic>> backupStatus() async =>
      ((await _c.call(webdavBackupStatusMethod)) as Map).cast<String, dynamic>();

  static Future<String> downloadBackup(String remotePath, String localDir) async =>
      (await _c.call(webdavDownloadBackupMethod, [remotePath, localDir])) as String;

  /// 导出格式能力列表：每项含 id / name / extension / implemented。
  static Future<List<Map<String, dynamic>>> exportFormats() async {
    final data = await _c.call(exportFormatsMethod);
    if (data == null) return const [];
    return (data as List).cast<Map<String, dynamic>>();
  }

  /// 导出一本书到指定目录（目录为空时用内核默认 `<home>/exports`）。
  static Future<Map<String, dynamic>> exportBook(
    int bookId,
    String format,
    String outputDir,
  ) async =>
      ((await _c.call(exportBookMethod, [bookId, format, outputDir])) as Map)
          .cast<String, dynamic>();

  /// 编辑书籍信息。封面/简介传空串表示回落到书源值，`groupId<0` 不改分组。
  static Future<Map<String, dynamic>> saveBook({
    required int bookId,
    required String name,
    required String author,
    required String coverUrl,
    required String intro,
    required int groupId,
  }) async =>
      ((await _c.call(saveBookMethod, [
        bookId,
        name,
        author,
        coverUrl,
        intro,
        groupId,
      ])) as Map)
          .cast<String, dynamic>();

  /// 换源。`sourceId=0` 时由 core 按新地址自动匹配书源。
  static Future<Map<String, dynamic>> changeSource({
    required int bookId,
    required int sourceId,
    required String bookUrl,
  }) async =>
      ((await _c.call(changeSourceMethod, [bookId, sourceId, bookUrl]))
              as Map)
          .cast<String, dynamic>();

  // ---- 分组管理 ----

  static Future<Map<String, dynamic>> createGroup(String name) async =>
      ((await _c.call(createGroupMethod, [name])) as Map).cast<String, dynamic>();

  /// 后三个可选参数对应原版分组的封面/本组排序方式/是否参与目录更新。
  static Future<void> updateGroup(
    int id, {
    required String name,
    required bool show,
    required int order,
    required String cover,
    required int bookSort,
    required bool enableRefresh,
  }) =>
      _c.call(updateGroupMethod, [
        id,
        name,
        show,
        order,
        cover,
        bookSort,
        enableRefresh,
      ]);

  static Future<void> deleteGroup(int id) => _c.call(deleteGroupMethod, [id]);

  // ---- 书架管理（多选批量） ----

  static Future<void> setCanUpdate(List<int> ids, bool enabled) =>
      _c.call(setCanUpdateMethod, [ids, enabled]);

  static Future<void> moveToGroups(List<int> ids, int groupId) =>
      _c.call(moveToGroupsMethod, [ids, groupId]);

  static Future<void> addToGroups(List<int> ids, int groupId) =>
      _c.call(addToGroupsMethod, [ids, groupId]);

  static Future<void> deleteBooks(List<int> ids) =>
      _c.call(deleteBooksMethod, [ids]);

  /// 列出在架书籍；[sort] 取当前分组的 bookSort（-1 用内核默认顺序）。
  static Future<List<Map<String, dynamic>>> listBooks(int groupId, int sort) =>
      _c.callList(Api.shelfListBooks, [groupId, sort]);

  /// 更新一本书的目录，返回 added / removed / total / hasUpdate。
  static Future<Map<String, dynamic>> refreshToc(int bookId) async =>
      ((await _c.call(refreshTocMethod, [bookId])) as Map)
          .cast<String, dynamic>();

  /// 详情页刷新：重抓详情 + 目录（不改名、不覆盖自定义字段）。
  static Future<Map<String, dynamic>> refreshBook(int bookId) async =>
      ((await _c.call(refreshBookMethod, [bookId])) as Map)
          .cast<String, dynamic>();

  /// 清空一本书的正文缓存（DB + 磁盘图片 + 正在跑的任务）。
  static Future<void> purgeBookCache(int bookId) =>
      _c.call(purgeBookCacheMethod, [bookId]);

  /// 批量换源：按书名 + 作者精确搜索，返回 succeeded/skipped/failed/errors。
  static Future<Map<String, dynamic>> batchChangeSource(
    List<int> bookIds,
    int sourceId,
  ) async =>
      ((await _c.call(batchChangeSourceMethod, [bookIds, sourceId])) as Map)
          .cast<String, dynamic>();

  /// 书架 JSON 导入：参数是 JSON 数组文本或返回它的 http(s) 地址。
  static Future<Map<String, dynamic>> importBookshelf(
    String jsonOrUrl,
    int groupId,
  ) async =>
      ((await _c.call(importBookshelfMethod, [jsonOrUrl, groupId])) as Map)
          .cast<String, dynamic>();

  /// 导出书架 JSON（name/author/intro 数组），与原版 books.json 同格式。
  static Future<String> exportBookshelf(int groupId) async =>
      (await _c.call(exportBookshelfMethod, [groupId])) as String;

  /// 这本书是否有本地源文件（本地 txt/epub/漫画返回 true，网络书 false）。
  ///
  /// 书架点击时用来区分「本地漫画逐页取图」与「网络漫画按 images 渲染」。
  static Future<bool> isLocalBook(int bookId) async {
    final path = await _c.call('Reader.GetLocalFile', [bookId]);
    return '${path ?? ''}'.trim().isNotEmpty;
  }
}
