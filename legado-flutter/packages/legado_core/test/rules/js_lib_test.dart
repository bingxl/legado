import 'package:legado_core/src/js/js_engine_factory.dart';
import 'package:legado_core/src/rules/rules.dart';
import 'package:test/test.dart';

/// jsLib 注入：书源里的公共函数库必须对每条规则脚本可见。
void main() {
  group('jsLib', () {
    test('jsLib 定义的函数对规则脚本可见', () async {
      final context = SimpleRuleContext(
        js: createJsEngine(),
        baseUrl: 'https://example.test/',
        jsLib: 'function shout(s){ return String(s).toUpperCase() + "!"; }',
      );
      addTearDown(context.js.dispose);

      expect(await context.evalJs('shout("ok")', null), 'OK!');
    });

    test('jsLib 里的常量与脚本内的 result 绑定共存', () async {
      final context = SimpleRuleContext(
        js: createJsEngine(),
        baseUrl: 'https://example.test/',
        jsLib: 'var prefix = "书名：";\nfunction label(s){ return prefix + s; }',
      );
      addTearDown(context.js.dispose);

      final value = await context.evalJs('label(result)', '斗破');
      expect(value, '书名：斗破');
    });

    test('没有 jsLib 时同名调用失败（证明上面的可见性来自 jsLib）', () async {
      final context = SimpleRuleContext(
        js: createJsEngine(),
        baseUrl: 'https://example.test/',
      );
      addTearDown(context.js.dispose);

      await expectLater(
        context.evalJs('shout("ok")', null),
        throwsA(anything),
      );
    });

    test('jsLib 里引用 java 宿主也能跑（函数体内调用）', () async {
      final context = SimpleRuleContext(
        js: createJsEngine(),
        baseUrl: 'https://example.test/',
        jsLib: 'function b64(s){ return java.base64Encode(s); }',
      );
      addTearDown(context.js.dispose);

      expect(await context.evalJs('b64("hi")', null), 'aGk=');
    });
  });
}
