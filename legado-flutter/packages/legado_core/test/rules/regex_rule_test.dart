import 'package:legado_core/src/rules/regex_rule.dart';
import 'package:test/test.dart';

void main() {
  group('regexReplace', () {
    test('全量替换', () {
      expect(regexReplace('a1b2', r'\d', '#'), 'a#b#');
    });

    test('\$1 分组引用', () {
      expect(regexReplace('/book/12', r'/book/(\d+)', r'id=$1'), 'id=12');
    });

    test(r'${1} 分组引用', () {
      expect(regexReplace('/book/12', r'/book/(\d+)', r'id=${1}'), 'id=12');
    });

    test('只替换首个匹配', () {
      expect(
        regexReplace('a1b2', r'\d', '#', replaceFirst: true),
        '#',
      );
    });

    test('空替换等于删除', () {
      expect(regexReplace('书名一', '书名', ''), '一');
    });

    test('无匹配时全量替换返回原串', () {
      expect(regexReplace('abc', r'\d', '#'), 'abc');
    });

    test('无匹配且 replaceFirst 返回空串（对齐 Kotlin）', () {
      expect(regexReplace('abc', r'\d', '#', replaceFirst: true), '');
    });

    test('非法正则退化为字面量替换', () {
      expect(regexReplace('a[b', '[b', 'X'), 'aX');
    });

    test(r'Java 的 \A \Z 转 Dart 边界', () {
      expect(regexReplace('abc', r'\Aabc\Z', 'x'), 'x');
    });

    test('内联 (?i) 忽略大小写', () {
      expect(regexReplace('AbC', '(?i)abc', 'x'), 'x');
    });
  });

  group('regexGetElement', () {
    test('单级取全部分组', () {
      expect(
        regexGetElement('<a href="/1">甲</a>', [r'<a href="(.*?)">(.*?)</a>']),
        ['<a href="/1">甲</a>', '/1', '甲'],
      );
    });

    test('多级：前级缩范围，末级取分组', () {
      expect(
        regexGetElement('<a>1</a><a>2</a>', [r'<a>(.*?)</a>', r'\d']),
        ['1'],
      );
    });

    test('无匹配返回 null', () {
      expect(regexGetElement('abc', [r'\d']), isNull);
    });

    test('非法正则返回 null', () {
      expect(regexGetElement('abc', ['[a-']), isNull);
    });
  });

  group('regexGetElements', () {
    test('每行一组分组', () {
      final rows = regexGetElements('<a>1</a><a>2</a>', [r'<a>(.*?)</a>']);
      expect(rows, [
        ['<a>1</a>', '1'],
        ['<a>2</a>', '2'],
      ]);
    });

    test('多级提取', () {
      final rows = regexGetElements(
        '<ul><li>1</li><li>2</li></ul>',
        [r'<li>(.*?)</li>', r'\d'],
      );
      // 前级把范围缩成 "12"，末级对整串逐个匹配
      expect(rows, [
        ['1'],
        ['2'],
      ]);
    });

    test('无匹配返回空列表', () {
      expect(regexGetElements('abc', [r'\d']), isEmpty);
    });
  });
}
