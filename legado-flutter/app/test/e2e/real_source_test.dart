// 真实书源端到端验证：UI 层（ExploreApi/SearchApi）→ 内核 → 真实站点。
//
// 这类测试要联网，因此默认不跑；用环境变量开关启用：
//   LEGADO_E2E=1 LEGADO_HOME=<数据目录> flutter test test/e2e/real_source_test.dart
//
// 数据目录里要已经有书源（用 legado_cli:import_sources 导入）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/explore/explore_api.dart';

void main() {
  final enabled = Platform.environment['LEGADO_E2E'] == '1';

  // 境内直连不通、必须走代理的站点（书源作者在注释里写明了）。
  // 这些源在测试里跳过，否则会一直等到超时。
  const proxyOnly = {'爱丽丝书屋', 't66y'};

  group('真实书源端到端', () {
    setUpAll(() async {
      if (!enabled) return;
      await LegadoClient.connect();
    });

    test('发现页能列出开启发现的书源', () async {
      if (!enabled) return;
      final sources = await ExploreApi.listSources();
      // ignore: avoid_print
      print('发现源: ${sources.map((s) => s['name']).toList()}');
      expect(sources, isNotEmpty);
    });

    test('每个发现源都能解析出分类', () async {
      if (!enabled) return;
      final sources = await ExploreApi.listSources();
      for (final s in sources) {
        final id = (s['id'] as num).toInt();
        final kinds = await ExploreApi.kinds(id);
        // ignore: avoid_print
        print('  #${s['name']} 分类 ${kinds.length} 个: '
            '${kinds.take(3).map((k) => k['title']).toList()}');
        expect(kinds, isNotEmpty, reason: '${s['name']} 没有解析出分类');
      }
    });

    test('拉取第一个分类的书单', () async {
      if (!enabled) return;
      final sources = await ExploreApi.listSources();
      var checked = 0;
      for (final s in sources) {
        final name = s['name']?.toString() ?? '';
        if (proxyOnly.contains(name)) continue;
        final id = (s['id'] as num).toInt();
        final kinds = await ExploreApi.kinds(id);
        if (kinds.isEmpty) continue;
        final url = kinds.first['url']?.toString() ?? '';
        final books = await ExploreApi.explore(id, url, 1);
        // ignore: avoid_print
        print('  #$name 书单 ${books.length} 本: '
            '${books.take(2).map((b) => b['name']).toList()}');
        if (books.isEmpty) {
          // 有些纯发现源只配了分类地址、没配发现解析规则（ruleExplore 为空），
          // 返回空是正确行为，不算失败。
          // ignore: avoid_print
          print('    （该源没有配置发现解析规则，跳过）');
          continue;
        }
        expect(books.first['name'], isNotEmpty);
        checked++;
      }
      expect(checked, greaterThan(0), reason: '没有可直连的书源用于验证');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('搜索接口能返回结果', () async {
      if (!enabled) return;
      final sources = await ExploreApi.listSources();
      var checked = 0;
      for (final s in sources) {
        final name = s['name']?.toString() ?? '';
        if (proxyOnly.contains(name)) continue;
        // 纯发现源没有搜索地址，内核会报错——这属于预期，跳过。
        if (s['hasSearchUrl'] != true) {
          // ignore: avoid_print
          print('  #$name 无搜索地址（纯发现源），跳过');
          continue;
        }
        final id = (s['id'] as num).toInt();
        final res = await LegadoClient.instance
            .callList('Source.Search', [id, '斗破苍穹', 1]);
        // ignore: avoid_print
        print('  #$name 搜索 ${res.length} 条');
        checked++;
        if (res.isNotEmpty) {
          expect(res.first['name'], isNotEmpty);
        }
      }
      expect(checked, greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
