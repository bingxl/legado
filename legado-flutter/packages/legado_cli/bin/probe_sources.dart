// 用真实书源跑一遍内核能力：列表 → 搜索 → 详情 → 目录 → 正文。
//
// 目的：在桌面 UI 之外，先确认内核层与真实站点的对接是否通。
// 用法: dart run legado_cli:probe_sources [home] [sourceId]
import 'dart:convert';
import 'dart:io';

import 'package:legado_core/legado_core.dart';

String _s(dynamic v, [int max = 80]) {
  final t = v?.toString() ?? '';
  return t.length > max ? '${t.substring(0, max)}…' : t;
}

Future<void> main(List<String> args) async {
  final home = args.isNotEmpty
      ? args[0]
      : 'C:/Users/bingx/work/code/legado/.legado-dev';

  final core = LegadoCore.instance;
  await core.init(homeDir: home, version: 'dev', host: 'cli');

  final list = ((await core.call('Source.List', []) as List)
          .cast<Map<String, dynamic>>())
      .where((s) => s['enabled'] == true)
      .toList();
  stdout.writeln('启用的书源 ${list.length} 个:');
  for (final s in list) {
    stdout.writeln('  #${s['id']} ${s['name']}  (${s['url']})');
  }

  for (final src in list) {
    final id = src['id'] as int;
    stdout.writeln('\n=== #${id} ${src['name']} ===');

    // 1) 发现分类
    try {
      final kinds = await core.call('Source.ExploreKinds', [id]);
      final kl = (kinds as List?) ?? [];
      stdout.writeln('  [发现分类] ${kl.length} 个');
      for (final k in kl.take(6)) {
        stdout.writeln('    - ${_s(k)}');
      }
    } catch (e) {
      stdout.writeln('  [发现分类] 失败: ${_s(e)}');
    }

    // 2) 搜索
    try {
      final sw = Stopwatch()..start();
      final res = await core.call('Source.Search', [id, '斗破苍穹']);
      sw.stop();
      final rl = (res as List?) ?? [];
      stdout.writeln('  [搜索] ${rl.length} 条, ${sw.elapsedMilliseconds}ms');
      for (final r in rl.take(3)) {
        stdout.writeln('    - ${_s(r['name'])} | ${_s(r['author'], 30)}');
      }
      if (rl.isNotEmpty) {
        final book = rl.first;

        // 3) 详情
        try {
          final detail = await core.call(
            'Source.PreviewBook',
            [id, book['url'] ?? book['bookUrl']],
          );
          final d = (detail as Map?) ?? {};
          stdout.writeln('  [详情] ${_s(d['name'])} | 简介 ${_s(d['intro'], 60)}');
        } catch (e) {
          stdout.writeln('  [详情] 失败: ${_s(e)}');
        }

        // 4) 目录
        try {
          final toc = await core.call(
            'Reader.GetChapters',
            [id, book['url'] ?? book['bookUrl']],
          );
          final tl = (toc as List?) ?? [];
          stdout.writeln('  [目录] ${tl.length} 章');
          for (final c in tl.take(3)) {
            stdout.writeln('    - ${_s(c['title'])}');
          }

          // 5) 正文
          if (tl.isNotEmpty) {
            try {
              final content = await core.call('Reader.GetContent', [
                id,
                book['url'] ?? book['bookUrl'],
                tl.first['url'] ?? tl.first['index'] ?? 0,
              ]);
              final ct = _s(content, 120);
              stdout.writeln('  [正文] ${ct.isEmpty ? "(空)" : ct}');
            } catch (e) {
              stdout.writeln('  [正文] 失败: ${_s(e)}');
            }
          }
        } catch (e) {
          stdout.writeln('  [目录] 失败: ${_s(e)}');
        }
      }
    } catch (e) {
      stdout.writeln('  [搜索] 失败: ${_s(e)}');
    }
  }

  await core.close();
}
