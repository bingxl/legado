// 桌面端 UI 层的真实书源端到端验证：
// 搜索 → 试读入库 → 目录 → 正文，全程走 UI 用的同一套 controller / API。
//
// 这类测试要联网，因此默认不跑；用环境变量开关启用：
//   LEGADO_E2E=1 LEGADO_HOME=<数据目录> flutter test test/e2e/reader_flow_test.dart
//
// 数据目录里要已经有书源（用 legado_cli:import_sources 导入）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/reader/reader_controller.dart';
import 'package:legado/features/reader/reader_style.dart';

/// 境内直连不通、必须走代理的站点。
const proxyOnly = {'爱丽丝书屋', 't66y'};

void main() {
  final enabled = Platform.environment['LEGADO_E2E'] == '1';

  group('真实书源：桌面端阅读链路', () {
    late List<Map<String, dynamic>> sources;

    setUpAll(() async {
      if (!enabled) return;
      await LegadoClient.connect();
      final raw = await LegadoClient.instance.callList('Source.List', const []);
      sources = raw
          .cast<Map<String, dynamic>>()
          .where((s) => s['enabled'] == true)
          .toList();
    });

    test('搜索 → 试读 → 目录：目录不该只有页面上的 20 章', () async {
      if (!enabled) return;

      Map<String, dynamic>? target;
      Map<String, dynamic>? hit;
      for (final s in sources) {
        final name = s['name']?.toString() ?? '';
        if (proxyOnly.contains(name)) continue;
        if (s['hasSearchUrl'] != true) continue;
        final id = (s['id'] as num).toInt();
        final res = await LegadoClient.instance
            .callList('Source.Search', [id, '斗破苍穹', 1]);
        // ignore: avoid_print
        print('  #$name 搜索 ${res.length} 条');
        if (res.isEmpty) continue;
        target = res.first.cast<String, dynamic>();
        hit = s;
        break;
      }
      expect(target, isNotNull, reason: '没有可直连且带搜索地址的书源');
      expect(hit, isNotNull);

      final sourceId = (hit!['id'] as num).toInt();
      final bookUrl = target!['bookUrl'].toString();

      // 试读：抓详情 + 目录并入库，返回 bookId。
      final preview = await LegadoClient.instance
          .call('Source.PreviewBook', [sourceId, bookUrl]);
      final p = (preview as Map).cast<String, dynamic>();
      final bookId = (p['bookId'] ?? p['id']) as num;
      // ignore: avoid_print
      print('  试读 bookId=$bookId  来源=${hit!['name']}');

      final chapters = await LegadoClient.instance
          .callList('Reader.GetChapters', [bookId.toInt()]);
      // ignore: avoid_print
      print('  目录 ${chapters.length} 章，前 3 条: '
          '${chapters.take(3).map((c) => c['title']).toList()}');

      expect(chapters, isNotEmpty);
      // 每个章节都得有可访问的 URL，否则点开会白屏。
      for (final c in chapters.take(20)) {
        expect((c['url'] ?? '').toString(), isNotEmpty);
      }

      // 目录规则里用了 `java.ajax` 取全量章节的书源，
      // 目录数必须远大于目录页上直接列出的 20 条。
      final name = hit!['name'].toString();
      if (name.contains('漫画客')) {
        expect(chapters.length, greaterThan(100),
            reason: '漫画客目录应取到全量章节（POST /morechapter），'
                '实际只有 ${chapters.length} 章');
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('正文能取到内容（漫画源应带图片直链）', () async {
      if (!enabled) return;

      // 复用上一条用例入库的书：重新搜一次拿 bookUrl。
      Map<String, dynamic>? target;
      for (final s in sources) {
        final name = s['name']?.toString() ?? '';
        if (proxyOnly.contains(name)) continue;
        if (s['hasSearchUrl'] != true) continue;
        final id = (s['id'] as num).toInt();
        final res = await LegadoClient.instance
            .callList('Source.Search', [id, '斗破苍穹', 1]);
        if (res.isEmpty) continue;
        target = res.first.cast<String, dynamic>();
        break;
      }
      expect(target, isNotNull);

      final sourceId = (sources
              .firstWhere((s) =>
                  s['hasSearchUrl'] == true &&
                  !proxyOnly.contains(s['name']?.toString() ?? ''))['id'] as num)
          .toInt();
      final preview = await LegadoClient.instance
          .call('Source.PreviewBook', [sourceId, target!['bookUrl'].toString()]);
      final bookId = ((preview as Map)['bookId'] ?? (preview as Map)['id']) as num;

      // 用 UI 层的 ReaderController 走一遍，验证「桌面端真能打开这本书」。
      final controller = ReaderController(
        bookId: bookId.toInt(),
        initialChapter: -1,
        style: const ReaderStyle(),
      );
      await controller.load();
      addTearDown(controller.dispose);

      expect(controller.error, isNull, reason: '阅读器加载失败: ${controller.error}');
      expect(controller.chapters, isNotEmpty);
      expect(controller.chapterTitle, isNotEmpty);
      // ignore: avoid_print
      print('  书名=${controller.bookTitle} 章节=${controller.chapters.length} '
          '当前章=${controller.chapterTitle} 图片=${controller.images.length}');
      expect(controller.images, isNotEmpty,
          reason: '漫画源正文应带图片直链');
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
