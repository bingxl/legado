import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/book/chapter_preview.dart';

List<Map<String, dynamic>> _chapters(int count) {
  return [
    for (var i = 0; i < count; i++) {'index': i, 'title': '第 ${i + 1} 章'},
  ];
}

void main() {
  group('previewChapters', () {
    test('默认只取前 20 章', () {
      final preview = previewChapters(_chapters(35));
      expect(preview, hasLength(20));
      expect(preview.first['title'], '第 1 章');
      expect(preview.last['title'], '第 20 章');
    });

    test('不足 limit 时全部返回', () {
      expect(previewChapters(_chapters(3)), hasLength(3));
    });

    test('空目录返回空', () {
      expect(previewChapters(const []), isEmpty);
    });

    test('limit 非正数返回空', () {
      expect(previewChapters(_chapters(10), limit: 0), isEmpty);
      expect(previewChapters(_chapters(10), limit: -1), isEmpty);
    });

    test('返回值是副本，不影响原目录', () {
      final chapters = _chapters(3);
      previewChapters(chapters).removeAt(0);
      expect(chapters, hasLength(3));
    });
  });
}
