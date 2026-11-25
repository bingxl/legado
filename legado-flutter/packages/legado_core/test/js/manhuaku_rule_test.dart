import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'helpers.dart';

/// 漫画库（manhuaku）取图脚本的回归测试。
///
/// 脚本直接从仓库书源 `sources/manhuaku_comic_source.json` 读取，保证测的就是
/// 会下发到客户端的那一份规则。
///
/// 线上页面把图片前缀写成三种形态：
/// - `'https://us2…/uuid/' + ('4e13…-uuid' || '第01话') + '/'`
///   —— 括号里第一个字面量是真值，取它（多数漫画走这里）
/// - `'https://us2…/uuid/' + ('' || '第01話') + '/'`
///   —— 第一个是空串，JS `||` 短路后应取「第01話」；早期实现只抓第一个字面量，
///   于是拼成 `…/uuid//1.webp`（双斜杠）整章 404，表现就是「有的漫画能看、
///   有的整章白图」
/// - `'https://us2…/uuid/' + '' + '/'` —— 没有子目录
List<String> _srcs(String html) => RegExp(r'<img src="([^"]+)"')
    .allMatches(html)
    .map((m) => m.group(1)!)
    .toList();

/// 从 CWD 向上找仓库根，定位书源文件（`dart test` 可能在 legado-flutter 或包目录下跑）。
File _sourceFile() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final f = File('${dir.path}/sources/manhuaku_comic_source.json');
    if (f.existsSync()) return f;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到 sources/manhuaku_comic_source.json，CWD=${Directory.current.path}');
}

Future<String> _ruleScript() async {
  final raw = jsonDecode(await _sourceFile().readAsString()) as List<Object?>;
  final source = raw.first as Map<String, Object?>;
  // 书源文件里 ruleContent 既可能是内联对象，也可能是 JSON 字符串。
  final rawRule = source['ruleContent'];
  final ruleContent = rawRule is String
      ? jsonDecode(rawRule) as Map<String, Object?>
      : rawRule as Map<String, Object?>;
  final content = ruleContent['content'] as String;
  expect(content.startsWith('@js:'), isTrue, reason: '漫画库正文规则应为 @js:');
  return content.substring('@js:'.length);
}

Future<List<String>> _run(String pageHtml) async {
  final out = await run(await _ruleScript(), bindings: {'result': pageHtml});
  expect(out, isA<String>());
  return _srcs(out as String);
}

void main() {
  test('括号内首个字面量为空串时取 || 右值，而不是拼出双斜杠', () async {
    const html = '''
<script>
var totalPages = parseInt('3');
var imgBaseUrl = 'https://us2.manhuaku.com.cn/mh/ba0e8d0527784d509601d97be97a2779/' + ('' || '第01話') + '/';
</script>
''';
    final srcs = await _run(html);
    expect(srcs, hasLength(3));
    expect(
      srcs.first,
      'https://us2.manhuaku.com.cn/mh/ba0e8d0527784d509601d97be97a2779/第01話/1.webp',
    );
    expect(srcs.last, endsWith('/第01話/3.webp'));
    // 双斜杠正是线上 404 的形态，必须守住。
    for (final s in srcs) {
      expect(s, isNot(contains('//1.webp')));
      expect(RegExp(r'[^:/]//').hasMatch(s.replaceFirst('https://', '')), isFalse,
          reason: '路径里不该出现空目录: $s');
    }
  });

  test('括号内首个字面量为真值时取它（UUID 子目录）', () async {
    const uuid = 'f9991e5f-f865-4594-8609-5a8f41d0e701';
    final html = '''
var totalPages = parseInt('2');
var imgBaseUrl = 'https://us2.manhuaku.com.cn/mh/ba0e8d0527784d509601d97be97a2779/' + ('$uuid' || '番外1') + '/';
''';
    final srcs = await _run(html);
    expect(srcs, [
      'https://us2.manhuaku.com.cn/mh/ba0e8d0527784d509601d97be97a2779/$uuid/1.webp',
      'https://us2.manhuaku.com.cn/mh/ba0e8d0527784d509601d97be97a2779/$uuid/2.webp',
    ]);
  });

  test('无子目录（+ \'\' +）时压掉重复斜杠，但不碰协议里的 //', () async {
    const html = '''
var totalPages = parseInt('1');
var imgBaseUrl = 'https://us2.manhuaku.com.cn/mh/aaa/' + '' + '/';
''';
    final srcs = await _run(html);
    expect(srcs, ['https://us2.manhuaku.com.cn/mh/aaa/1.webp']);
  });

  test('脚本缺失时回退 data-src，跳过 loading 占位图', () async {
    const html = '''
<img class="lazy" data-src="/resource/image/loading.svg" src="/resource/image/loading.svg">
<img class="lazy" data-src="https://us2.manhuaku.com.cn/mh/x/1.webp" src="/resource/image/loading.svg">
''';
    expect(await _run(html), ['https://us2.manhuaku.com.cn/mh/x/1.webp']);
  });
}
