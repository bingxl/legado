import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/reader_controller.dart';

/// 内核按「原始图片 URL」返回本地路径，UI 侧按归一化地址查，
/// 否则协议相对地址 / HTML 转义地址会查不到缓存、又退回网络。
void main() {
  test('按归一化地址建索引，协议相对与 HTML 实体都能命中', () {
    final paths = parseCachedImagePaths(<String, String>{
      '//cdn.example.com/p1.png': r'C:\cache\1.png',
      'https://cdn.example.com/p2.png?a=1&amp;b=2': r'C:\cache\2.png',
    });

    expect(paths, hasLength(2));
    expect(paths['https://cdn.example.com/p1.png'], r'C:\cache\1.png');
    expect(
      paths['https://cdn.example.com/p2.png?a=1&b=2'],
      r'C:\cache\2.png',
    );
  });

  test('坏数据当作无缓存，不能让整章打不开', () {
    expect(parseCachedImagePaths(null), isEmpty);
    expect(parseCachedImagePaths('not-a-map'), isEmpty);
    expect(parseCachedImagePaths(<String, String>{}), isEmpty);
  });
}
