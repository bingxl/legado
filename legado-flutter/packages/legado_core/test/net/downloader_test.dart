import 'dart:async';
import 'dart:io';
import 'dart:io' as io show HttpRequest;

import 'package:legado_core/src/net/net.dart';
import 'package:test/test.dart';

import 'support.dart';

/// 按 `Range` 头返回内容，模拟一个支持断点续传的静态文件服务器。
Future<void> serveContent(
  io.HttpRequest raw,
  List<int> content, {
  bool supportRange = true,
  int delayPerChunkMs = 0,
  int chunkSize = 4096,
}) async {
  final rangeHeader = raw.headers.value('range');
  if (rangeHeader == null || !supportRange) {
    raw.response.statusCode = 200;
    raw.response.headers.set('content-length', content.length.toString());
    for (var i = 0; i < content.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, content.length);
      raw.response.add(content.sublist(i, end));
      if (delayPerChunkMs > 0) {
        await raw.response.flush();
        await Future<void>.delayed(Duration(milliseconds: delayPerChunkMs));
      }
    }
    await raw.response.close();
    return;
  }

  final m = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader);
  final start = m == null ? 0 : int.parse(m.group(1)!);
  if (start >= content.length) {
    raw.response.statusCode = 416;
    raw.response.headers.set('content-range', 'bytes */${content.length}');
    await raw.response.close();
    return;
  }
  final slice = content.sublist(start);
  raw.response.statusCode = 206;
  raw.response.headers
    ..set('content-range', 'bytes $start-${content.length - 1}/${content.length}')
    ..set('content-length', slice.length.toString());
  for (var i = 0; i < slice.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, slice.length);
    raw.response.add(slice.sublist(i, end));
    if (delayPerChunkMs > 0) {
      await raw.response.flush();
      await Future<void>.delayed(Duration(milliseconds: delayPerChunkMs));
    }
  }
  await raw.response.close();
}

void main() {
  late TestServer server;
  late NetClient net;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('legado_dl');
    net = NetClient(limiter: testLimiter(), maxRetries: 0);
  });

  tearDown(() async {
    net.close();
    await server.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  String pathOf(String name) => '${dir.path}/$name';

  test('正常下载：内容与落盘一致，无残留 .part', () async {
    final content = utf8Bytes('hello-image-bytes');
    server = await TestServer.start((req, raw) => serveContent(raw, content));
    final downloader = Downloader(client: net);
    final savePath = pathOf('cover.jpg');

    await downloader.download(
      DownloadTask(uri: server.uri('/cover.jpg'), savePath: savePath),
    );

    final file = File(savePath);
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), content);
    expect(await File('$savePath.part').exists(), isFalse);
    expect(server.last.header('range'), isNull, reason: '首次下载不该带 Range');
    downloader.close();
  });

  test('父目录不存在时自动创建', () async {
    final content = utf8Bytes('nested');
    server = await TestServer.start((req, raw) => serveContent(raw, content));
    final downloader = Downloader(client: net);
    final savePath = '${dir.path}/a/b/c/cover.jpg';

    await downloader.download(
      DownloadTask(uri: server.uri('/x'), savePath: savePath),
    );
    expect(await File(savePath).readAsBytes(), content);
    downloader.close();
  });

  test('206 续传：.part 已有 5 字节时追加剩余部分', () async {
    final content = utf8Bytes('0123456789');
    await File(pathOf('x.jpg.part')).writeAsBytes(content.sublist(0, 5));
    server = await TestServer.start((req, raw) => serveContent(raw, content));
    final downloader = Downloader(client: net);

    await downloader.download(
      DownloadTask(uri: server.uri('/x.jpg'), savePath: pathOf('x.jpg')),
    );

    expect(server.last.header('range'), 'bytes=5-');
    expect(await File(pathOf('x.jpg')).readAsBytes(), content);
    expect(await File(pathOf('x.jpg.part')).exists(), isFalse);
    downloader.close();
  });

  test('目标文件已存在时按它的长度续传', () async {
    final content = utf8Bytes('abcdefghij');
    // 没有 .part，只有半截目标文件——模拟上次「直接写目标」的老版本残留。
    await File(pathOf('y.jpg')).writeAsBytes(content.sublist(0, 4));
    server = await TestServer.start((req, raw) => serveContent(raw, content));
    final downloader = Downloader(client: net);

    await downloader.download(
      DownloadTask(uri: server.uri('/y.jpg'), savePath: pathOf('y.jpg')),
    );

    expect(server.last.header('range'), 'bytes=4-');
    expect(await File(pathOf('y.jpg')).readAsBytes(), content);
    downloader.close();
  });

  test('服务器不支持 Range（回 200）时从头覆盖', () async {
    final content = utf8Bytes('FULL-CONTENT');
    await File(pathOf('z.jpg.part')).writeAsBytes(utf8Bytes('GARBAGE'));
    server = await TestServer.start(
      (req, raw) => serveContent(raw, content, supportRange: false),
    );
    final downloader = Downloader(client: net);

    await downloader.download(
      DownloadTask(uri: server.uri('/z.jpg'), savePath: pathOf('z.jpg')),
    );

    expect(server.last.header('range'), 'bytes=7-', reason: '仍然会先请求续传');
    final bytes = await File(pathOf('z.jpg')).readAsBytes();
    expect(bytes, content);
    expect(bytes.length, content.length, reason: '不能把旧内容和全文拼在一起');
    downloader.close();
  });

  test('416 视为已完成', () async {
    final content = utf8Bytes('already-complete');
    await File(pathOf('done.jpg.part')).writeAsBytes(content);
    server = await TestServer.start((req, raw) => serveContent(raw, content));
    final downloader = Downloader(client: net);

    await downloader.download(
      DownloadTask(uri: server.uri('/done.jpg'), savePath: pathOf('done.jpg')),
    );

    expect(await File(pathOf('done.jpg')).readAsBytes(), content);
    expect(await File(pathOf('done.jpg.part')).exists(), isFalse);
    downloader.close();
  });

  test('取消：抛异常并清掉 .part，目标文件不产生', () async {
    // 512KB 才能被读成多块：小文件会被一次读完，取消点落在循环之外，
    // 测不出「传输中途取消」这条路径。
    final content = List<int>.generate(512 * 1024, (i) => i % 251);
    server = await TestServer.start(
      (req, raw) =>
          serveContent(raw, content, chunkSize: 16 * 1024, delayPerChunkMs: 2),
    );
    final downloader = Downloader(client: net);
    final cancel = CancelToken();
    final savePath = pathOf('cancel.jpg');
    var events = 0;

    await expectLater(
      downloader.download(
        DownloadTask(uri: server.uri('/c.jpg'), savePath: savePath),
        cancel: cancel,
        onProgress: (p) {
          if (p.status == DownloadStatus.running && p.received > 0) {
            events++;
            cancel.cancel();
          }
        },
      ),
      throwsA(isA<DownloadCanceledException>()),
    );

    expect(events, greaterThan(0));
    expect(await File(savePath).exists(), isFalse);
    expect(await File('$savePath.part').exists(), isFalse);
    downloader.close();
  });

  test('取消令牌已被取消时直接失败，不发请求', () async {
    server = await TestServer.start((req, raw) => serveContent(raw, const [1]));
    final downloader = Downloader(client: net);
    final cancel = CancelToken()..cancel();

    await expectLater(
      downloader.download(
        DownloadTask(uri: server.uri('/x'), savePath: pathOf('x')),
        cancel: cancel,
      ),
      throwsA(isA<DownloadCanceledException>()),
    );
    expect(server.requestCount, 0);
    downloader.close();
  });

  test('5xx 会重试，第二次成功', () async {
    final content = utf8Bytes('retry-ok');
    server = await TestServer.start((req, raw) async {
      if (server.requestCount == 1) {
        raw.response.statusCode = 500;
        await raw.response.close();
        return;
      }
      await serveContent(raw, content);
    });
    final downloader = Downloader(client: net, maxRetry: 2);

    await downloader.download(
      DownloadTask(uri: server.uri('/r'), savePath: pathOf('r.jpg')),
    );

    expect(server.requestCount, 2);
    expect(await File(pathOf('r.jpg')).readAsBytes(), content);
    downloader.close();
  });

  test('重试耗尽后抛 DownloadException 且不留半截文件', () async {
    server = await TestServer.start((req, raw) async {
      raw.response.statusCode = 503;
      await raw.response.close();
    });
    final downloader = Downloader(client: net, maxRetry: 1);

    await expectLater(
      downloader.download(
        DownloadTask(uri: server.uri('/dead'), savePath: pathOf('dead.jpg')),
      ),
      throwsA(isA<DownloadException>()),
    );
    expect(server.requestCount, 2);
    expect(await File(pathOf('dead.jpg')).exists(), isFalse);
    expect(await File(pathOf('dead.jpg.part')).exists(), isFalse);
    downloader.close();
  });

  test('404 不重试，直接失败', () async {
    server = await TestServer.start((req, raw) async {
      raw.response.statusCode = 404;
      await raw.response.close();
    });
    final downloader = Downloader(client: net, maxRetry: 3);

    await expectLater(
      downloader.download(
        DownloadTask(uri: server.uri('/missing'), savePath: pathOf('m.jpg')),
      ),
      throwsA(isA<DownloadException>()),
    );
    expect(server.requestCount, 1);
    downloader.close();
  });

  test('超过大小上限直接拒绝', () async {
    final content = List<int>.filled(4096, 7);
    server = await TestServer.start((req, raw) => serveContent(raw, content));
    final downloader = Downloader(client: net, maxBytes: 1024);

    await expectLater(
      downloader.download(
        DownloadTask(uri: server.uri('/big'), savePath: pathOf('big.bin')),
      ),
      throwsA(
        isA<DownloadException>().having(
          (e) => e.message,
          'message',
          contains('上限'),
        ),
      ),
    );
    expect(await File(pathOf('big.bin')).exists(), isFalse);
    expect(await File(pathOf('big.bin.part')).exists(), isFalse);
    downloader.close();
  });

  test('默认上限是 100MB', () {
    expect(kMaxDownloadBytes, 100 * 1024 * 1024);
  });

  test('进度回调给出 received / total / done', () async {
    final content = List<int>.filled(3000, 3);
    server = await TestServer.start(
      (req, raw) => serveContent(raw, content, chunkSize: 500),
    );
    final downloader = Downloader(client: net);
    final events = <DownloadProgress>[];

    await downloader.download(
      DownloadTask(uri: server.uri('/p'), savePath: pathOf('p.bin')),
      onProgress: events.add,
    );

    expect(events, isNotEmpty);
    expect(events.first.status, DownloadStatus.running);
    expect(events.last.status, DownloadStatus.done);
    expect(events.last.received, 3000);
    expect(events.last.total, 3000);
    expect(events.last.fraction, 1.0);
    expect(
      events.any((e) => e.total == 3000 && e.status == DownloadStatus.running),
      isTrue,
      reason: '运行中也要能拿到总长度',
    );
    downloader.close();
  });

  test('并发不超过 maxConcurrent', () async {
    var active = 0;
    var peak = 0;
    server = await TestServer.start((req, raw) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      active--;
      await serveContent(raw, List<int>.filled(64, 1));
    });
    final downloader = Downloader(client: net, maxConcurrent: 2);
    final tasks = List.generate(6, (i) {
      return DownloadTask(
        uri: server.uri('/img$i.jpg'),
        savePath: pathOf('img$i.jpg'),
      );
    });

    final statuses = await downloader.downloadAll(tasks);

    expect(statuses, everyElement(DownloadStatus.done));
    expect(peak, lessThanOrEqualTo(2));
    expect(peak, greaterThanOrEqualTo(2), reason: '不该退化成串行');
    downloader.close();
  });

  test('downloadAll 汇总状态，单个失败不影响其他', () async {
    server = await TestServer.start((req, raw) async {
      if (req.uri.path == '/bad') {
        raw.response.statusCode = 404;
        await raw.response.close();
        return;
      }
      await serveContent(raw, utf8Bytes('ok'));
    });
    final downloader = Downloader(client: net);

    final statuses = await downloader.downloadAll([
      DownloadTask(uri: server.uri('/good1'), savePath: pathOf('g1')),
      DownloadTask(uri: server.uri('/bad'), savePath: pathOf('bad')),
      DownloadTask(uri: server.uri('/good2'), savePath: pathOf('g2')),
    ]);

    expect(statuses, [
      DownloadStatus.done,
      DownloadStatus.failed,
      DownloadStatus.done,
    ]);
    expect(await File(pathOf('g1')).exists(), isTrue);
    expect(await File(pathOf('g2')).exists(), isTrue);
    expect(await File(pathOf('bad')).exists(), isFalse);
    downloader.close();
  });

  test('downloadAll 取消时剩余任务标记为 canceled', () async {
    server = await TestServer.start((req, raw) {
      return serveContent(raw, List<int>.filled(2000, 2), chunkSize: 500);
    });
    final downloader = Downloader(client: net, maxConcurrent: 1);
    final cancel = CancelToken();
    final statuses = await downloader.downloadAll(
      List.generate(3, (i) {
        return DownloadTask(
          uri: server.uri('/c$i'),
          savePath: pathOf('c$i'),
        );
      }),
      cancel: cancel,
      onProgress: (index, p) {
        if (p.received > 0) cancel.cancel();
      },
    );

    expect(statuses, everyElement(DownloadStatus.canceled));
    downloader.close();
  });

  test('任务头会透传给服务端（防盗链 Referer）', () async {
    server = await TestServer.start((req, raw) => serveContent(raw, const [1, 2]));
    final downloader = Downloader(client: net);

    await downloader.download(
      DownloadTask(
        uri: server.uri('/hot.jpg'),
        savePath: pathOf('hot.jpg'),
        headers: {'Referer': 'https://site.com/chapter/1'},
      ),
    );

    expect(server.last.header('referer'), 'https://site.com/chapter/1');
    downloader.close();
  });
}
