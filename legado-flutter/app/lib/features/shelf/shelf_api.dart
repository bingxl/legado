/// 书架「添加书籍」与 WebDAV 相关的 core 调用封装。
///
/// 各 feature 自带方法名常量（共享 Api 文件不允许追加，见 api.dart 注释）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/bridge/legado_client.dart';

class ShelfApi {
  ShelfApi._();

  /// 编辑书籍信息（书名/作者/封面/简介/分组）。
  static const saveBookMethod = 'Shelf.SaveBook';

  /// 换源（core 负责重建目录与迁移进度）。
  static const changeSourceMethod = 'Source.ChangeSource';

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

  /// 本地文件导入：把字节写到应用私有临时目录（Android content:// 没有可读 path），
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
    for (final f in files) {
      // 用时间戳前缀避免同名文件互相覆盖。
      final safeName = p.basename(f.name).replaceAll(RegExp(r'[^\w.\-]'), '_');
      final path = p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_$safeName');
      await File(path).writeAsBytes(f.bytes, flush: true);
      paths.add(path);
    }
    final result = await _c.call(importLocalFiles, [paths, groupId]);
    return (result as Map).cast<String, dynamic>();
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

  /// 这本书是否有本地源文件（本地 txt/epub/漫画返回 true，网络书 false）。
  ///
  /// 书架点击时用来区分「本地漫画逐页取图」与「网络漫画按 images 渲染」。
  static Future<bool> isLocalBook(int bookId) async {
    final path = await _c.call('Reader.GetLocalFile', [bookId]);
    return '${path ?? ''}'.trim().isNotEmpty;
  }
}
