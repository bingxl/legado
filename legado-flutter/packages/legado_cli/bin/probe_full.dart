// 用真实书源跑一遍完整链路：搜索 → 试读入库 → 目录 → 正文。
//
// 关键：目录/正文要按 **bookId** 取，不是 sourceId。
// 试读（Source.PreviewBook）会把书抓进 books 表并返回 bookId。
import 'dart:convert';
import 'dart:io';

import 'package:legado_core/legado_core.dart';

String _s(dynamic v, [int max = 90]) {
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

  // 只测有搜索地址的源
  final searchable = <Map<String, dynamic>>[];
  for (final s in list) {
    final ok = await core.call('Source.Validate', [
      [s['id']],
      {'Keyword': '斗破苍穹', 'check': true},
    ]);
    final issues = (ok as List?) ?? [];
    final hasSearchUrl = !(issues as List).any((i) {
      final m = i as Map;
      return m['level'] == 'error' &&
          (m['field'] == 'searchUrl' || m['field'] == 'ruleSearch');
    });
    if (hasSearchUrl) searchable.add(s);
  }

  stdout.writeln('有搜索地址的书源: ${searchable.map((s) => s['name']).join(", ")}\n');

  for (final src in searchable) {
    final id = src['id'] as int;
    stdout.writeln('=== #${id} ${src['name']} ===');

    try {
      final res = await core.call('Source.Search', [id, '斗破苍穹']);
      final rl = (res as List?) ?? [];
      stdout.writeln('  [搜索] ${rl.length} 条');
      if (rl.isEmpty) continue;
      for (final r in rl.take(2)) {
        stdout.writeln('    - ${_s(r['name'])} | ${_s(r['author'], 24)} | ${_s(r['bookUrl'], 50)}');
      }

      final book = rl.first;
      final bookUrl = book['bookUrl'];

      // 试读入库：返回 bookId + 章节数
      final preview = await core.call('Source.PreviewBook', [id, bookUrl]);
      final p = (preview as Map?) ?? {};
      final bookId = p['bookId'] ?? p['id'];
      stdout.writeln('  [试读] bookId=$bookId  章节数=${p['totalChapterNum'] ?? p['chapterCount']}');

      if (bookId == null) {
        stdout.writeln('  [试读] 未返回 bookId: ${_s(p)}');
        continue;
      }

      // 目录
      final toc = await core.call('Reader.GetChapters', [bookId]);
      final tl = (toc as List?) ?? [];
      stdout.writeln('  [目录] ${tl.length} 章');
      for (final c in tl.take(3)) {
        stdout.writeln('    - ${_s(c['title'])}');
      }

      // 正文
      if (tl.isNotEmpty) {
        final content = await core.call('Reader.GetContent', [bookId, 0]);
        final c = (content as Map?) ?? {};
        final html = c['html']?.toString() ?? '';
        stdout.writeln('  [正文] ${html.isEmpty ? "(空)" : _s(html, 150)}');
        final imgs = c['images'];
        if (imgs is List && imgs.isNotEmpty) {
          stdout.writeln('    图片 ${imgs.length} 张，例：${_s(imgs.first, 100)}');
        }
      }
    } catch (e) {
      stdout.writeln('  [失败] ${_s(e, 200)}');
    }
    stdout.writeln('');
  }

  await core.close();
}
