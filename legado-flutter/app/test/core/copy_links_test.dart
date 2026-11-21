import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/widgets/copy_links.dart';

/// 「复制地址」的候选生成是纯函数，这里只验它——UI 侧的点按链路靠真机验收。
void main() {
  test('网络书：书籍 / 书源 / 封面地址按顺序给出', () {
    final links = bookCopyLinks(
      bookUrl: 'https://example.test/book/1',
      origin: 'https://example.test',
      coverUrl: 'https://img.example.test/1.jpg',
    );
    expect(links.map((l) => l.label), ['书籍地址', '书源地址', '封面地址']);
    expect(links.first.value, 'https://example.test/book/1');
  });

  test('本地书 origin 是 local 标记，不当地址复制', () {
    final links = bookCopyLinks(
      bookUrl: '/sdcard/books/a.txt',
      origin: 'local',
      coverUrl: '',
    );
    expect(links.map((l) => l.label), ['书籍地址']);
    expect(links.single.value, '/sdcard/books/a.txt');
  });

  test('空白值一律剔除，并 trim 掉首尾空格', () {
    final links = bookCopyLinks(
      bookUrl: '  https://example.test/book/2  ',
      origin: '   ',
      coverUrl: '',
      chapterUrl: '\n',
    );
    expect(links, hasLength(1));
    expect(links.single.value, 'https://example.test/book/2');
  });

  test('阅读器传本章地址时排最后', () {
    final links = bookCopyLinks(
      bookUrl: 'https://example.test/book/1',
      chapterUrl: 'https://example.test/ch/9',
    );
    expect(links.map((l) => l.label), ['书籍地址', '本章地址']);
    expect(links.last.value, 'https://example.test/ch/9');
  });

  test('全部为空时返回空列表（UI 据此禁用复制入口）', () {
    expect(bookCopyLinks(), isEmpty);
  });

  test('书源地址只在带协议时才收录', () {
    expect(bookCopyLinks(origin: 'example.test').map((l) => l.label), isEmpty);
    expect(
      bookCopyLinks(origin: 'http://a.test').map((l) => l.label),
      ['书源地址'],
    );
  });
}
