import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../net/net.dart';

/// 网络书图片的磁盘缓存。
///
/// 原版 legado 缓存一章 = 正文文本 + 正文里每张图片：`CacheBook.download()`
/// 用 `BookHelp.saveImages()` 把图片下载到
/// `<externalFiles>/book_cache/<book>/images/<md5(src)>.<ext>`，阅读时从文件
/// 解码。Flutter 之前只把图片地址 `jsonEncode` 进 `chapter_cache`，目录
/// `<home>/cache/chapter/<bookId>/<idx>/` 只有删除逻辑没有写入方 —— 断网
/// 后漫画章一张都打不开。
///
/// 这里补齐那一半：下载仍走统一的 [Downloader]（原子落盘 + 断点续传 + 限流），
/// 缓存键用 FNV-1a 64 而不是原版的 MD5 —— 文件名只要本实现内部稳定即可，
/// 没必要为了对齐哈希值与 `crypto` 依赖绑死。目录结构与删除逻辑保持一致。
class ImageCacheService {
  ImageCacheService({
    required String homeDir,
    NetClient? net,
    Downloader? downloader,
  })  : _homeDir = homeDir,
        _net = net ?? NetClient(),
        _downloader = downloader;

  final String _homeDir;
  final NetClient _net;
  Downloader? _downloader;

  Downloader get downloader => _downloader ??= Downloader(client: _net);

  /// 图片落盘目录：与 `CacheService._removeChapterDir` 的删除路径一致。
  String chapterDir(int bookId, int index) =>
      p.join(_homeDir, 'cache', 'chapter', '$bookId', '$index');

  /// 删除本章已落盘的图片目录（缓存过期、单章删除时用）。
  ///
  /// 图片是可再生资源，删不掉不该让主操作失败，所以这里吞掉异常。
  void removeChapterDir(int bookId, int index) =>
      _removeDir(Directory(chapterDir(bookId, index)));

  /// 删除整本书的图片缓存目录（与 CacheService.purgeBook 配套）。
  void removeBookDir(int bookId) =>
      _removeDir(Directory(p.join(_homeDir, 'cache', 'chapter', '$bookId')));

  void _removeDir(Directory dir) {
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // 图片是可再生资源；删不掉不该让主操作失败。
    }
  }

  /// 单张图片的完整路径。
  String imagePath(int bookId, int index, String url) {
    final normalized = normalizeImageUrl(url) ?? url;
    return p.join(
      chapterDir(bookId, index),
      '${imageKey(normalized)}.${imageExtension(normalized)}',
    );
  }

  /// 已落盘的图片：`原始 URL → 绝对路径`。
  ///
  /// 用原始 URL 当 key（而不是下标），正文插图和漫画章都能按地址查；
  /// UI 侧又会对地址做一次归一化，所以两种写法都能命中。
  Map<String, String> cachedPaths(
    int bookId,
    int index,
    Iterable<String> urls,
  ) {
    final out = <String, String>{};
    if (_homeDir.isEmpty) return out;
    for (final url in urls) {
      if (normalizeImageUrl(url) == null) continue;
      final path = imagePath(bookId, index, url);
      final file = File(path);
      if (file.existsSync() && file.lengthSync() > 0) out[url] = path;
    }
    return out;
  }

  /// 本章图片是否全部落盘（原版 `BookHelp.hasImageContent` 的简化版）。
  ///
  /// 与完整性判定不同，这里不解码图片：下载器已经保证「完整落盘或没有文件」，
  /// 而解码要在 UI 侧按屏幕尺寸做，内核解码一遍纯属浪费。
  bool hasAllImages(int bookId, int index, Iterable<String> urls) {
    for (final url in urls) {
      if (normalizeImageUrl(url) == null) continue;
      final file = File(imagePath(bookId, index, url));
      if (!file.existsSync() || file.lengthSync() == 0) return false;
    }
    return true;
  }

  /// 下载本章缺失的图片，返回本次**实际写入**的字节数（已存在的也计入）。
  ///
  /// 单张失败不影响其它张，也不让整章缓存失败 —— 原版 `BookHelp.saveImage`
  /// 内部同样吞掉单图异常。取消由调用方传 [cancel]（缓存任务的 Cancel）。
  Future<int> downloadChapter(
    int bookId,
    int index,
    Iterable<String> urls, {
    CancelToken? cancel,
  }) async {
    if (_homeDir.isEmpty) return 0;
    final tasks = <DownloadTask>[];
    var bytes = 0;
    for (final url in urls) {
      final normalized = normalizeImageUrl(url);
      if (normalized == null) continue;
      final uri = Uri.tryParse(normalized);
      if (uri == null) continue;
      final file = File(imagePath(bookId, index, url));
      if (file.existsSync()) {
        final length = file.lengthSync();
        if (length > 0) {
          bytes += length;
          continue;
        }
      }
      tasks.add(
        DownloadTask(
          uri: uri,
          savePath: file.path,
          headers: imageRequestHeaders(normalized),
        ),
      );
    }
    if (tasks.isEmpty) return bytes;

    final statuses = await downloader.downloadAll(tasks, cancel: cancel);
    for (var i = 0; i < statuses.length; i++) {
      if (statuses[i] != DownloadStatus.done) continue;
      final file = File(tasks[i].savePath);
      if (file.existsSync()) bytes += file.lengthSync();
    }
    return bytes;
  }

  void close() {
    _downloader?.close();
    _net.close();
  }

  /// 缓存键：FNV-1a 64 位，输出 16 位十六进制（与原版 md5Encode16 位数一致）。
  static String imageKey(String url) {
    var hash = 0xCBF29CE484222325;
    const prime = 0x100000001B3;
    for (final byte in utf8.encode(url)) {
      hash = (hash ^ byte) * prime;
    }
    return (hash & 0x7FFFFFFFFFFFFFFF).toRadixString(16).padLeft(16, '0');
  }

  static String imageExtension(String url) {
    final uri = Uri.tryParse(url);
    var ext = uri == null
        ? ''
        : uri.path.split('.').last.toLowerCase();
    if (!_imageExtensions.contains(ext)) ext = 'jpg';
    return ext;
  }

  static const Set<String> _imageExtensions = <String>{
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'avif',
    'heic',
  };

  /// 与 app 层 `imageHeaders` 同口径：UA + 图片自身 origin 作 Referer。
  ///
  /// 内核不能依赖 Flutter 应用包，这里复制一份纯 Dart 实现。改规则时两边
  /// 要一起改，否则「在线能看、缓存下来 403」会非常难排查。
  static Map<String, String> imageRequestHeaders(String url) {
    final uri = Uri.tryParse(url);
    final origin = uri != null && uri.host.isNotEmpty
        ? '${uri.scheme}://${uri.host}/'
        : '';
    return <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      if (origin.isNotEmpty) 'Referer': origin,
    };
  }

  /// 与 app 层 `normalizeImageUrl` 同口径（见该文件的注释）。
  static String? normalizeImageUrl(String? raw) {
    if (raw == null) return null;
    var url = raw.trim();
    if (url.isEmpty) return null;
    url = url
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    if (url.startsWith('//')) url = 'https:$url';
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final scheme = uri.scheme.toLowerCase();
    if ((scheme != 'http' && scheme != 'https') || uri.host.isEmpty) {
      return null;
    }
    return url;
  }
}
