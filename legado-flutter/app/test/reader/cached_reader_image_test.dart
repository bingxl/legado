import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/widgets/cached_reader_image.dart';
import 'package:path/path.dart' as p;

/// 图片章离线可读的最后一环：内核把图片落盘后，阅读器必须真的读文件，
/// 而不是继续 Image.network —— 否则缓存了也白缓存。
void main() {
  late Directory home;
  late String localPath;

  // 1x1 透明 PNG：让 FileImage 能真正解码，不会被 widget test 报成坏图。
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  );

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('legado-cached-image');
    localPath = p.join(home.path, 'page.png');
    File(localPath).writeAsBytesSync(png);
  });

  tearDownAll(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Widget buildSubject(String url, String? path) {
    return MaterialApp(
      home: Scaffold(
        body: CachedReaderImage(
          url: url,
          localPath: path,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
        ),
      ),
    );
  }

  testWidgets('命中磁盘缓存时用 FileImage，不发网络请求', (tester) async {
    await tester.pumpWidget(
      buildSubject('https://cdn.example.com/page.png', localPath),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<FileImage>());
    expect((image.image as FileImage).file.path, localPath);
  });

  testWidgets('缓存路径不存在时回落网络图，并带防盗链 Referer', (tester) async {
    await tester.pumpWidget(
      buildSubject(
        'https://cdn.example.com/page.png',
        p.join(home.path, 'deleted.png'),
      ),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<NetworkImage>());
    final network = image.image as NetworkImage;
    expect(network.url, 'https://cdn.example.com/page.png');
    expect(network.headers?['Referer'], 'https://cdn.example.com/');
  });

  testWidgets('没有缓存路径时行为与改动前一致', (tester) async {
    await tester.pumpWidget(buildSubject('https://cdn.example.com/a.webp', null));
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<NetworkImage>());
    expect((image.image as NetworkImage).url, 'https://cdn.example.com/a.webp');
  });

  testWidgets('非法地址且无本地缓存时走统一失败占位', (tester) async {
    await tester.pumpWidget(buildSubject('/relative/a.png', null));
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });
}
