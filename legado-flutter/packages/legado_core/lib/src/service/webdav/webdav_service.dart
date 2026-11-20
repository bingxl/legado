/// WebDAV 域服务：配置、目录浏览、书籍导入、数据库备份。
///
/// 设计要点（对齐 `docs/方法契约表.md` WebDAV 11 条与 Kotlin 原版）：
/// - 配置存 `app_settings`（webdav.*），密码明文落盘但视图永不返回；
/// - 书籍导入是「先下载到临时目录 → 复用 LibraryService.importLocalFiles」，
///   后台单任务 + 状态查询 + 协作式取消，半成品 `.part` 取消时清理；
/// - 备份用 sqlite3 原生 backup API（WAL 安全），不替换运行中的数据库。
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../kernel/errors.dart';
import '../../store/store.dart';
import '../library/library_service.dart';
import 'webdav_client.dart';
import 'webdav_dto.dart';

final Logger _log = Logger('legado.webdav');

/// 配置项键名。
const String _kUrl = 'webdav.url';
const String _kUsername = 'webdav.username';
const String _kPassword = 'webdav.password';
const String _kRootPath = 'webdav.rootPath';
const String _kAutoSync = 'webdav.autoSync';

/// 默认服务器（坚果云），与 Kotlin `AppWebDav.kt` 一致。
const String kDefaultWebDavUrl = 'https://dav.jianguoyun.com/dav/';

class WebDAVService {
  WebDAVService({
    required StoreDaos daos,
    required LibraryService library,
    required String homeDir,
  })  : _daos = daos,
        _library = library,
        _homeDir = homeDir;

  final StoreDaos _daos;
  final LibraryService _library;
  final String _homeDir;

  /// 导入任务（单实例，契约无 jobID）。
  WebDAVImportJob? _job;
  final Set<String> _cancelledPaths = <String>{};
  bool _cancelAll = false;
  bool _closed = false;

  /// 临时下载目录。
  String get _tmpDir => p.join(_homeDir, 'webdav_tmp');

  // ---- 配置 ----------------------------------------------------------

  WebDavConfigView getConfig() {
    final settings = _daos.settings;
    final url = settings.get(_kUrl) ?? '';
    final password = settings.get(_kPassword) ?? '';
    return WebDavConfigView(
      url: url,
      username: settings.get(_kUsername) ?? '',
      hasPassword: password.isNotEmpty,
      rootPath: settings.get(_kRootPath) ?? 'legado',
      autoSync: settings.get(_kAutoSync) == 'true',
      configured: url.trim().isNotEmpty,
    );
  }

  Future<WebDavConfigView> saveConfig(
    String url,
    String username,
    String password,
    String rootPath,
    bool autoSync,
  ) async {
    final patch = <String, String?>{
      _kUrl: WebDavClient.normalizeUrl(url),
      _kUsername: username,
      _kRootPath: rootPath.trim(),
      _kAutoSync: autoSync ? 'true' : 'false',
    };
    // password="" 表示保持原密码（契约）。
    if (password.isNotEmpty) patch[_kPassword] = password;
    await _daos.settings.putAll(patch);
    return getConfig();
  }

  WebDavConnection _connection() {
    final settings = _daos.settings;
    final url = settings.get(_kUrl) ?? '';
    if (url.trim().isEmpty) {
      throw const LegadoException(ErrorCode.sourceEmpty, '尚未配置 WebDAV');
    }
    return WebDavConnection(
      url: url,
      username: settings.get(_kUsername) ?? '',
      password: settings.get(_kPassword) ?? '',
      rootPath: settings.get(_kRootPath) ?? 'legado',
    );
  }

  WebDavClient _client() => WebDavClient(_connection());

  // ---- 目录 / 文件 ----------------------------------------------------

  Future<void> test() => _client().test();

  Future<List<Map<String, Object?>>> list(String relPath) async {
    final entries = await _client().list(relPath);
    return [for (final e in entries) e.toJson()];
  }

  Future<List<Map<String, Object?>>> scanBooks(String relPath) async {
    final entries = await _client().scanBooks(relPath);
    return [for (final e in entries) RemoteBookView(e).toJson()];
  }

  Future<void> delete(String relPath) => _client().delete(relPath);

  // ---- 备份 -----------------------------------------------------------

  /// 当前同步进度（备份用，单独一份）。
  final SyncProgress _backupProgress = SyncProgress();

  SyncProgress backupStatus() => _backupProgress;

  /// 用 sqlite3 backup API 把运行中的库拷到临时文件，再 PUT 到远端。
  Future<SyncProgress> uploadBackup() async {
    final progress = _backupProgress;
    progress
      ..state = SyncState.running
      ..phase = 'backup'
      ..total = 1
      ..done = 0
      ..failed = 0
      ..bytes = 0
      ..totalBytes = 0
      ..message = '正在备份数据库';
    try {
      final db = _daos.db;
      final tempDir = Directory(_tmpDir);
      if (!tempDir.existsSync()) tempDir.createSync(recursive: true);
      final tempPath = p.join(tempDir.path, 'legado-backup.db');
      final dest = sqlite3.open(tempPath);
      try {
        // backup 的进度是 0~1 的粗粒度比例；先按 0..100 展示，落盘后换成真实字节。
        await db.backup(dest, nPage: 100).forEach((ratio) {
          progress.bytes = (ratio * 100).round();
        });
      } finally {
        dest.close();
      }
      final file = File(tempPath);
      final length = await file.length();
      progress
        ..phase = 'upload'
        ..totalBytes = length
        ..bytes = 0
        ..message = '正在上传备份';

      final client = _client();
      final rel = 'backup/legado-${DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}.db';
      await client.upload(rel, await file.readAsBytes(),
          contentType: 'application/octet-stream');
      try {
        await file.delete();
      } catch (_) {}

      progress
        ..bytes = length
        ..done = 1
        ..state = SyncState.done
        ..message = '备份完成';
      return progress;
    } on LegadoException catch (e) {
      progress
        ..state = SyncState.failed
        ..failed = 1
        ..message = e.message;
      return progress;
    } on Object catch (e) {
      progress
        ..state = SyncState.failed
        ..failed = 1
        ..message = '$e';
      return progress;
    }
  }

  /// 下载远端备份到 [localDir]，不替换运行中的数据库。
  Future<String> downloadBackup(String remotePath, String localDir) async {
    final dir = Directory(localDir.isEmpty ? _tmpDir : localDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final name = p.basename(remotePath).isEmpty ? 'legado-restored.db' : p.basename(remotePath);
    final dest = p.join(dir.path, name);
    final bytes = await _client().download(remotePath);
    await File(dest).writeAsBytes(bytes, flush: true);
    return dest;
  }

  // ---- 书籍导入 -------------------------------------------------------

  /// 启动导入（立即回执，后台执行）。
  WebDAVImportJob startBookImport(List<String> relPaths, int groupID) {
    final job = WebDAVImportJob(
      state: SyncState.running,
      phase: 'download',
      total: relPaths.length,
      current: '',
      message: '准备导入',
    );
    _job = job;
    _cancelAll = false;
    _cancelledPaths.clear();
    unawaited(_runImport(job, relPaths, groupID < 0 ? 0 : groupID));
    return job;
  }

  WebDAVImportJob importStatus() => _job ?? WebDAVImportJob(state: SyncState.idle);

  /// 取消全部导入；正在下载的 `.part` 会在下一个检查点删除。
  void cancelBookImport() {
    _cancelAll = true;
    _cancelledPaths.addAll(_job?.imported.map((e) => e['path'] as String) ?? const <String>[]);
    final job = _job;
    if (job != null && job.state == SyncState.running) {
      job.state = SyncState.canceled;
      job.message = '已取消';
    }
  }

  Future<void> _runImport(
    WebDAVImportJob job,
    List<String> relPaths,
    int groupID,
  ) async {
    final client = _clientSafe();
    if (client == null) {
      job
        ..state = SyncState.failed
        ..message = '尚未配置 WebDAV';
      return;
    }
    final tempDir = Directory(_tmpDir);
    if (!tempDir.existsSync()) tempDir.createSync(recursive: true);
    final downloaded = <String>[];

    try {
      // 阶段 1：下载远端文件到本地临时目录（.part 原子落盘）。
      for (final rel in relPaths) {
        if (_cancelAll || _closed) break;
        job.current = rel;
        final name = p.basename(rel);
        final finalPath = p.join(tempDir.path, '${DateTime.now().microsecondsSinceEpoch}_$name');
        final partPath = '$finalPath.part';
        try {
          final bytes = await client.download(rel);
          if (_cancelAll) {
            await _deleteQuietly(partPath);
            break;
          }
          final part = File(partPath);
          await part.writeAsBytes(bytes, flush: true);
          await part.rename(finalPath);
          downloaded.add(finalPath);
          job.done = downloaded.length;
          job.bytes += bytes.length;
        } on Object catch (e) {
          await _deleteQuietly(partPath);
          job.failed++;
          job.failures.add(<String, Object?>{'path': rel, 'reason': '$e'});
          _log.warning('下载失败 $rel: $e');
        }
      }

      // 阶段 2：复用 LibraryService 解析入库。
      if (!_cancelAll && !_closed && downloaded.isNotEmpty) {
        job.phase = 'import';
        final result = await _library.importLocalFiles(downloaded, groupID);
        job.imported.addAll(result.imported);
        for (final f in result.failed) {
          job.failures.add(f);
          job.failed++;
        }
      }

      // 清理临时文件。
      for (final path in downloaded) {
        await _deleteQuietly(path);
      }
      job
        ..state = _cancelAll ? SyncState.canceled : SyncState.done
        ..message = _cancelAll ? '已取消' : '导入完成：${job.imported.length} 本';
    } on Object catch (e) {
      for (final path in downloaded) {
        await _deleteQuietly(path);
      }
      job
        ..state = SyncState.failed
        ..message = '$e';
      _log.warning('WebDAV 导入失败: $e');
    }
  }

  WebDavClient? _clientSafe() {
    try {
      return _client();
    } on LegadoException {
      return null;
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  Future<void> close() async {
    _closed = true;
    _cancelAll = true;
    final dir = Directory(_tmpDir);
    if (dir.existsSync()) {
      // 只删 .part 半成品，保留已下载完整文件供下次复用。
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.part')) {
          await _deleteQuietly(entity.path);
        }
      }
    }
  }
}
