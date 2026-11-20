/// 统一的下载器：封面、插图、漫画页、整书文件都走这里。
///
/// 原版 legado 的下载散在 `help/book/` 与 `service/` 里，各自实现续传、重试、
/// 取消，行为并不一致（有的会留半张图、有的不重试）。Flutter 侧收成一个组件，
/// 规则是一句话：**要么得到一个完整的文件，要么什么都没有**。
///
/// 四条硬约束：
/// 1. 原子落盘：先写 `xxx.part`，成功后 rename；失败/取消删掉 `.part`。
///    绝不能出现「半张图被当成完整图缓存」——那种 bug 用户清缓存都修不好。
/// 2. 断点续传：目标文件（或残留的 `.part`）已有 N 字节时用 `Range: bytes=N-`
///    续；服务器回 200 说明不支持 Range，那就从头覆盖。
/// 3. 并发受控：复用 [RateLimiter]，默认全局 3 个并发。漫画站一次四十张图，
///    不限并发等于自爆。
/// 4. 单文件上限 100MB：防止一个畸形 `Content-Length` 把内存/磁盘打爆。
library;

import 'dart:async';
import 'dart:io';

import 'http_client.dart';
import 'net.dart' show NetClient;
import 'rate_limiter.dart';

/// 单个文件的大小上限（100 MiB）。
const int kMaxDownloadBytes = 100 * 1024 * 1024;

/// 下载状态。
enum DownloadStatus { pending, running, done, failed, canceled }

/// 一个下载任务。
class DownloadTask {
  const DownloadTask({
    required this.uri,
    required this.savePath,
    this.headers,
  });

  final Uri uri;

  /// 完整落盘路径（含文件名），父目录不存在会自动创建。
  final String savePath;

  /// 额外请求头。图片站点普遍有防盗链，`Referer` 必须带上。
  final Map<String, String>? headers;

  @override
  String toString() => 'DownloadTask($uri → $savePath)';
}

/// 进度快照。
class DownloadProgress {
  const DownloadProgress({
    required this.received,
    required this.status,
    this.total,
    this.error,
  });

  /// 已写入的字节数（续传时含续传前的部分）。
  final int received;

  /// 总字节数。服务器没给 `Content-Length` 时为 null。
  final int? total;

  final DownloadStatus status;

  /// 失败原因，仅 [DownloadStatus.failed] 时有值。
  final String? error;

  /// 进度比例；总长度未知时为 null。
  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    final f = received / t;
    return f > 1 ? 1 : f;
  }

  @override
  String toString() =>
      'DownloadProgress(${status.name}, $received/${total ?? '?'})';
}

/// 取消令牌。
///
/// 取消是「协作式」的：下载循环每收到一块数据检查一次，最坏情况多写一块
/// （通常 8–64KB），不会把半个文件留在盘上。
class CancelToken {
  bool _canceled = false;
  final Completer<void> _completer = Completer<void>();

  bool get isCanceled => _canceled;

  /// 取消发生时完成（供上层 `select` 式等待）。
  Future<void> get whenCanceled => _completer.future;

  void cancel() {
    if (_canceled) return;
    _canceled = true;
    if (!_completer.isCompleted) _completer.complete();
  }

  void throwIfCanceled() {
    if (_canceled) throw const DownloadCanceledException();
  }
}

/// 下载失败（不可重试，或重试耗尽）。
class DownloadException implements Exception {
  DownloadException(this.uri, this.message, {this.statusCode});

  final Uri uri;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'DownloadException($uri): $message';
}

/// 被 [CancelToken] 取消。
class DownloadCanceledException implements Exception {
  const DownloadCanceledException();

  @override
  String toString() => 'DownloadCanceledException';
}

/// 内部：可重试的失败。
class _RetryableException implements Exception {
  _RetryableException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// 下载器。
class Downloader {
  Downloader({
    required this.client,
    int maxConcurrent = 3,
    this.maxRetry = 2,
    this.maxBytes = kMaxDownloadBytes,
  }) : maxConcurrent = maxConcurrent < 1 ? 1 : maxConcurrent,
       _gate = RateLimiter(
         perHostConcurrency: maxConcurrent < 1 ? 1 : maxConcurrent,
         globalConcurrency: maxConcurrent < 1 ? 1 : maxConcurrent,
         minInterval: Duration.zero,
         // 0 表示关闭「连续失败退避」：重试节奏由本类控制，两套叠在一起
         // 会让一次失败被惩罚两次，漫画页会卡住好几秒。
         failureThreshold: 0,
       );

  /// 网络客户端（cookie / 限流 / 代理都在里面）。
  final NetClient client;

  /// 全局并发上限。
  final int maxConcurrent;

  /// 网络错误重试次数。
  final int maxRetry;

  /// 单文件大小上限。
  final int maxBytes;

  /// 并发闸门。所有任务共用同一个「虚拟 host」，于是 per-host 就等于全局。
  final RateLimiter _gate;

  /// 下载一个文件。
  ///
  /// 成功返回时目标文件已完整落盘。失败抛 [DownloadException]，
  /// 取消抛 [DownloadCanceledException]；两种情况都会清掉 `.part`。
  Future<void> download(
    DownloadTask task, {
    void Function(DownloadProgress progress)? onProgress,
    CancelToken? cancel,
  }) {
    return _gate.run('download', () => _download(task, onProgress, cancel));
  }

  /// 批量下载，返回每个任务最终的状态。
  ///
  /// 单个任务失败不影响其余任务；并发由 [maxConcurrent] 控制。
  Future<List<DownloadStatus>> downloadAll(
    List<DownloadTask> tasks, {
    void Function(int index, DownloadProgress progress)? onProgress,
    CancelToken? cancel,
  }) async {
    final statuses = List<DownloadStatus>.filled(
      tasks.length,
      DownloadStatus.pending,
    );
    await Future.wait(
      tasks.indexed.map((entry) async {
        final index = entry.$1;
        final task = entry.$2;
        try {
          await download(
            task,
            onProgress: onProgress == null
                ? null
                : (p) => onProgress(index, p),
            cancel: cancel,
          );
          statuses[index] = DownloadStatus.done;
        } on DownloadCanceledException {
          statuses[index] = DownloadStatus.canceled;
        } on DownloadException {
          statuses[index] = DownloadStatus.failed;
        } catch (_) {
          statuses[index] = DownloadStatus.failed;
        }
      }),
    );
    return statuses;
  }

  /// 关闭并发闸门。不关闭网络客户端（它归 [NetClient] 管）。
  void close() => _gate.close();

  // ---------------------------------------------------------------------------

  Future<void> _download(
    DownloadTask task,
    void Function(DownloadProgress progress)? onProgress,
    CancelToken? cancel,
  ) async {
    final target = File(task.savePath);
    final part = File('${task.savePath}.part');

    if (cancel?.isCanceled ?? false) {
      await _deleteQuietly(part);
      _emit(
        onProgress,
        const DownloadProgress(received: 0, status: DownloadStatus.canceled),
      );
      throw const DownloadCanceledException();
    }

    await _prepare(part: part, target: target);
    var received = await _length(part);
    _emit(
      onProgress,
      DownloadProgress(received: received, status: DownloadStatus.running),
    );

    Object? lastError;
    for (var attempt = 0; attempt <= maxRetry; attempt++) {
      if (attempt > 0) {
        // 200ms、400ms：下载失败多半是连接抖动，退避比立刻重连有效。
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
      }
      try {
        final result = await _attempt(
          task: task,
          part: part,
          received: received,
          onProgress: onProgress,
          cancel: cancel,
        );
        await _commit(part: part, target: target);
        _emit(
          onProgress,
          DownloadProgress(
            received: result.written,
            total: result.total,
            status: DownloadStatus.done,
          ),
        );
        return;
      } on DownloadCanceledException {
        await _deleteQuietly(part);
        _emit(
          onProgress,
          DownloadProgress(
            received: received,
            status: DownloadStatus.canceled,
          ),
        );
        rethrow;
      } on DownloadException catch (e) {
        await _deleteQuietly(part);
        _emit(
          onProgress,
          DownloadProgress(
            received: received,
            status: DownloadStatus.failed,
            error: e.message,
          ),
        );
        rethrow;
      } on _RetryableException catch (e) {
        lastError = e.reason;
      } on Object catch (e) {
        // 网络层异常（SocketException / ClientException / TimeoutException）
        // 都可以重试：下一轮会带着新的 `.part` 长度重新要 Range。
        lastError = e;
      }
      // 重试用「已落盘的部分」作为新起点，等于免费续传。
      received = await _length(part);
      _emit(
        onProgress,
        DownloadProgress(received: received, status: DownloadStatus.running),
      );
    }

    await _deleteQuietly(part);
    final message = '重试 $maxRetry 次后仍失败：$lastError';
    _emit(
      onProgress,
      DownloadProgress(
        received: received,
        status: DownloadStatus.failed,
        error: message,
      ),
    );
    throw DownloadException(task.uri, message);
  }

  /// 执行一次下载尝试，返回最终文件大小与总长度。
  Future<({int written, int? total})> _attempt({
    required DownloadTask task,
    required File part,
    required int received,
    required void Function(DownloadProgress progress)? onProgress,
    required CancelToken? cancel,
  }) async {
    final headers = <String, String>{...?task.headers};
    // 下载的是二进制：要求不压缩，否则 Content-Length 与实际字节对不上，
    // 进度会跳到 100% 然后再卡住。
    headers['accept-encoding'] = 'identity';
    if (received > 0) {
      headers['range'] = 'bytes=$received-';
    }

    final resp = await client.sendStream(
      HttpRequest(task.uri, method: 'GET', headers: headers),
    );
    final status = resp.statusCode;

    // 416 = 我们已经在文件末尾了，说明现有字节就是完整文件。
    if (status == 416) {
      if (received > 0) {
        await _discard(resp.bytes);
        return (written: received, total: received);
      }
      throw DownloadException(
        task.uri,
        '服务器返回 416 但本地没有已下载内容',
        statusCode: status,
      );
    }

    var append = false;
    int? total;
    if (status == 206) {
      append = true;
      final start = parseContentRangeStart(resp.header('content-range'));
      if (start != null && start != received) {
        // 服务器给的区间和本地对不上（文件被替换过），续传会写错位，从头来。
        append = false;
      }
      total = resp.contentRangeTotal ?? (received + (resp.contentLength ?? 0));
    } else if (status == 200) {
      append = false;
      total = resp.contentLength;
    } else if (status == 408 || status == 429 || status >= 500) {
      await _discard(resp.bytes);
      throw _RetryableException('HTTP $status');
    } else if (status >= 400) {
      await _discard(resp.bytes);
      throw DownloadException(task.uri, 'HTTP $status', statusCode: status);
    } else if (status < 200 || status >= 300) {
      await _discard(resp.bytes);
      throw _RetryableException('HTTP $status');
    }

    if (total != null && total > maxBytes) {
      await _discard(resp.bytes);
      throw DownloadException(
        task.uri,
        '文件 $total 字节超过上限 $maxBytes 字节',
        statusCode: status,
      );
    }

    var written = append ? received : 0;
    final raf = await part.open(mode: append ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in resp.bytes) {
        cancel?.throwIfCanceled();
        written += chunk.length;
        if (written > maxBytes) {
          throw DownloadException(
            task.uri,
            '文件超过上限 $maxBytes 字节',
            statusCode: status,
          );
        }
        await raf.writeFrom(chunk);
        _emit(
          onProgress,
          DownloadProgress(
            received: written,
            total: total,
            status: DownloadStatus.running,
          ),
        );
      }
    } finally {
      await raf.close();
    }

    // 最后一块写完之后才被取消也要认：调用方要的是「取消即无副作用」，
    // 不能因为抢在 commit 前一刻取消就把文件留下。
    cancel?.throwIfCanceled();

    if (total != null && written < total) {
      // 连接提前断开：已经写下的字节保留，下一轮续传。
      throw _RetryableException('连接提前结束（$written/$total）');
    }
    return (written: written, total: total);
  }

  /// 准备 `.part`：优先用它自己，其次从已存在的目标文件复制，最后建空文件。
  Future<void> _prepare({required File part, required File target}) async {
    final parent = target.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    if (await part.exists()) return;
    if (await target.exists()) {
      await target.copy(part.path);
      return;
    }
    await part.create(recursive: true);
  }

  /// 原子落盘：Windows 上 `rename` 不能覆盖已存在的目标，先删再改名。
  Future<void> _commit({required File part, required File target}) async {
    if (await target.exists()) {
      await target.delete();
    }
    await part.rename(target.path);
  }

  Future<int> _length(File file) async {
    if (!await file.exists()) return 0;
    return file.length();
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉（被占用）也不能让下载流程炸掉，下次会覆盖写。
    }
  }

  /// 丢掉不需要的响应体。
  ///
  /// 只取第一个事件就取消订阅：既让底层连接能回收，又不会为了一个错误页
  /// 把几十 MB 的 body 读进内存。
  Future<void> _discard(Stream<List<int>> stream) async {
    try {
      await stream.take(1).drain<void>();
    } catch (_) {
      // 已经断开的流，忽略。
    }
  }

  void _emit(
    void Function(DownloadProgress progress)? onProgress,
    DownloadProgress progress,
  ) {
    if (onProgress == null) return;
    try {
      onProgress(progress);
    } catch (_) {
      // 进度回调抛错不该中断下载（UI 里常见：widget 已被 dispose）。
    }
  }
}
