import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/tts/tts_module.dart';
import 'package:legado_core/src/service/tts/tts_segmenter.dart';
import 'package:test/test.dart';

String _repeat(String unit, int times) => List<String>.filled(times, unit).join();

/// 用例逐条对齐已删除的 Go 版 `core/modules/tts/segment_test.go`：
/// 断点、偏移、合并阈值是跨版本契约，两边算出来不一样就意味着
/// 「续读位置」在升级后会跳章。
void main() {
  group('分段规则', () {
    test('短句合并成一个片段', () {
      final segments = splitTtsSegments('第一句。第二句！第三句？', 120);
      expect(segments, hasLength(1));
      expect(segments.single.text, '第一句。第二句！第三句？');
      expect(segments.single.start, 0);
      expect(segments.single.end, 12);
    });

    test('超过上限要切分，且拼接后与原文一致', () {
      const text = '一二三四五。六七八九十。甲乙丙丁戊。';
      final segments = splitTtsSegments(text, 6);
      expect(segments.length, greaterThan(1));
      for (final segment in segments) {
        expect(segment.text.runes.length, lessThanOrEqualTo(12));
      }
      expect(segments.map((s) => s.text).join(), text);
      expect(
        segments.map((s) => s.index).toList(),
        List<int>.generate(segments.length, (i) => i),
      );
    });

    test('偏移是字符偏移，按偏移回切必须等于片段文本', () {
      final segments = splitTtsSegments('第一句。第二句。', 5);
      expect(segments, hasLength(2));
      expect([segments[0].start, segments[0].end], [0, 4]);
      expect([segments[1].start, segments[1].end], [4, 8]);

      final source = '第一句。第二句。'.runes.toList();
      for (final segment in segments) {
        final slice = String.fromCharCodes(
          source.sublist(segment.start, segment.end),
        );
        expect(slice, segment.text);
      }
    });

    test('多段落递增 paragraph，空行也占下标', () {
      final segments = splitTtsSegments('第一段内容。\n\n第二段内容。', 120);
      expect(segments, hasLength(2));
      expect(segments[0].paragraph, 0);
      expect(segments[1].paragraph, 2);
    });

    test('闭合引号与连续标点归属前一句', () {
      final segments = splitTtsSegments('他说：「好。」然后走了。', 8);
      expect(segments, hasLength(2));
      expect(segments[0].text, '他说：「好。」');
      expect(segments[1].text, '然后走了。');
    });

    test('空文本与纯空白返回空列表', () {
      expect(splitTtsSegments('', 10), isEmpty);
      expect(splitTtsSegments('  \n\n \t ', 10), isEmpty);
    });

    test('maxRunes <= 0 退回默认 120，负数不会切成一字一段', () {
      final text = _repeat('文', 200);
      expect(splitTtsSegments(text, 0), hasLength(2));
      final negative = splitTtsSegments(text, -5);
      expect(negative, hasLength(2));
      expect(negative.first.text.runes.length, defaultTtsMaxRunes);
    });

    test('超长单句按逗号二次切分', () {
      final text = '${_repeat('这是一个很长的分句，', 20)}结束。';
      final segments = splitTtsSegments(text, 20);
      expect(segments.length, greaterThanOrEqualTo(3));
      for (final segment in segments) {
        expect(segment.text.runes.length, lessThanOrEqualTo(60));
      }
    });

    test('段首空白计入偏移', () {
      final segments = splitTtsSegments('  他说。', 120);
      expect(segments, hasLength(1));
      expect(segments.single.start, 2);
      expect(segments.single.end, 5);
      expect(segments.single.text, '他说。');
    });

    test('找不到软断点时硬切，且不丢字', () {
      final segments = splitTtsSegments(_repeat('一', 25), 10);
      expect(segments.map((s) => s.text).join(), _repeat('一', 25));
      expect(segments.map((s) => s.text.runes.length).toList(), [10, 10, 5]);
    });

    test('emoji 按 rune 计数，不影响后续片段的偏移', () {
      // 一个 emoji 在 Dart 里是 2 个 UTF-16 码元、1 个 rune；
      // 这里断言的是 rune 口径 —— UI 侧若要 substring，需要自己换算。
      final segments = splitTtsSegments('😀第一句。第二句。', 6);
      expect(segments.map((s) => s.text).join(), '😀第一句。第二句。');
      final source = '😀第一句。第二句。'.runes.toList();
      for (final segment in segments) {
        expect(
          String.fromCharCodes(source.sublist(segment.start, segment.end)),
          segment.text,
        );
      }
    });
  });

  group('Tts.Segment 方法', () {
    late Registry registry;

    setUp(() {
      registry = Registry();
      TtsModule().register(
        registry,
        const LegadoContext(homeDir: '.', version: 'test', host: 'test'),
      );
    });

    test('返回的 JSON 字段与契约表一致', () async {
      final result = await registry.invoke('Tts.Segment', ['第一句。第二句。', 5])
          as List<Object?>;
      expect(result, hasLength(2));
      final first = result.first as Map<String, Object?>;
      expect(first.keys.toSet(), <String>{
        'index',
        'paragraph',
        'text',
        'start',
        'end',
      });
      expect(first['text'], '第一句。');
    });

    test('maxRunes 缺省 / 0 / 负数都按 120 处理', () async {
      final text = _repeat('文', 200);
      for (final args in <List<Object?>>[
        [text],
        [text, 0],
        [text, -3],
      ]) {
        final result = await registry.invoke('Tts.Segment', args) as List<Object?>;
        expect(result, hasLength(2), reason: 'args=$args');
      }
    });

    test('text 缺省为空串，maxRunes 传 double 也能取整', () async {
      expect(await registry.invoke('Tts.Segment', const []), isEmpty);
      final result = await registry.invoke('Tts.Segment', ['一二三四五', 2.9])
          as List<Object?>;
      expect(result, hasLength(3));
    });

    test('text 类型不对报参数错误而不是崩', () async {
      await expectLater(
        registry.invoke('Tts.Segment', [
          <String>['不是文本'],
        ]),
        throwsA(isA<Exception>()),
      );
    });
  });
}
