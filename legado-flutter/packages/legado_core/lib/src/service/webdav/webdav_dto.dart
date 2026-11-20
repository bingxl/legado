/// WebDAV 域对宿主暴露的视图对象（字段与 `docs/方法契约表.md` 一致）。
library;

import 'webdav_client.dart';

/// 配置视图：密码永不返回，只给一个 hasPassword 标志。
class WebDavConfigView {
  const WebDavConfigView({
    required this.url,
    required this.username,
    required this.hasPassword,
    required this.rootPath,
    required this.autoSync,
    required this.configured,
  });

  final String url;
  final String username;
  final bool hasPassword;
  final String rootPath;
  final bool autoSync;
  final bool configured;

  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        'username': username,
        'hasPassword': hasPassword,
        'rootPath': rootPath,
        'autoSync': autoSync,
        'configured': configured,
      };
}

/// 同步进度（备份上传 / 书籍导入共用）。
abstract final class SyncState {
  static const String idle = 'idle';
  static const String running = 'running';
  static const String done = 'done';
  static const String canceled = 'canceled';
  static const String failed = 'failed';
}

/// 一次备份同步的进度快照。
class SyncProgress {
  SyncProgress({
    this.state = SyncState.idle,
    this.phase = '',
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.current = '',
    this.bytes = 0,
    this.totalBytes = 0,
    this.message = '',
  });

  String state;
  String phase;
  int total;
  int done;
  int failed;
  String current;
  int bytes;
  int totalBytes;
  String message;

  Map<String, Object?> toJson() => <String, Object?>{
        'state': state,
        'phase': phase,
        'total': total,
        'done': done,
        'failed': failed,
        'current': current,
        'bytes': bytes,
        'totalBytes': totalBytes,
        'message': message,
      };
}

/// 远程书籍（ScanBooks 的结果）。
class RemoteBookView {
  RemoteBookView(this.entry) : format = _ext(entry.name);

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toUpperCase();
  }

  final WebDavEntry entry;
  final String format;

  Map<String, Object?> toJson() => <String, Object?>{
        ...entry.toJson(),
        'format': format,
      };
}

/// 书籍导入任务（单实例，ImportStatus 无参数）。
class WebDAVImportJob extends SyncProgress {
  WebDAVImportJob({
    super.state,
    super.phase,
    super.total,
    super.done,
    super.failed,
    super.current,
    super.bytes,
    super.totalBytes,
    super.message,
    List<Map<String, Object?>>? imported,
    List<Map<String, Object?>>? failures,
  })  : imported = imported ?? <Map<String, Object?>>[],
        failures = failures ?? <Map<String, Object?>>[];

  final List<Map<String, Object?>> imported;
  final List<Map<String, Object?>> failures;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        ...super.toJson(),
        'imported': imported,
        'failures': failures,
      };
}
