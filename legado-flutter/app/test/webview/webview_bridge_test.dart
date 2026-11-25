import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/webview/webview_bridge.dart';

/// `runJavaScriptReturningResult` 的返回值归一。
///
/// 这两个函数决定了两件容易出错的事：
/// 1. Cloudflare 挑战判定 —— 归一错了，验证页永远不自动完成；
/// 2. `outerHTML` 进正文 —— 不去引号的话正文第一行就是 `"<div ...`，
///    后续规则全部解析不到。
void main() {
  group('jsStringValue', () {
    test('Android 的 JSON 编码字符串：去引号并解转义', () {
      expect(jsStringValue('"a=1"'), 'a=1');
      expect(jsStringValue(r'"第一行\n第二行"'), '第一行\n第二行');
      expect(
        jsStringValue(r'"<div class=\"x\">正文</div>"'),
        '<div class="x">正文</div>',
      );
    });

    test('裸字符串原样返回', () {
      expect(jsStringValue('abc'), 'abc');
      expect(jsStringValue(''), '');
    });

    test('非字符串按字符串输出', () {
      expect(jsStringValue(42), '42');
      expect(jsStringValue(true), 'true');
      expect(jsStringValue(null), isNull);
    });

    test('只有一侧引号时不误删字符', () {
      expect(jsStringValue('"abc'), '"abc');
      expect(jsStringValue('a"'), 'a"');
    });
  });

  group('jsBooleanValue', () {
    test('true / "true" / 1 都为真', () {
      expect(jsBooleanValue(true), isTrue);
      expect(jsBooleanValue('true'), isTrue);
      expect(jsBooleanValue('"true"'), isTrue);
      expect(jsBooleanValue('1'), isTrue);
    });

    test('其余都为假', () {
      expect(jsBooleanValue(false), isFalse);
      expect(jsBooleanValue('false'), isFalse);
      expect(jsBooleanValue('"false"'), isFalse);
      expect(jsBooleanValue('0'), isFalse);
      expect(jsBooleanValue(null), isFalse);
      expect(jsBooleanValue(''), isFalse);
    });
  });
}
