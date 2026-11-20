import 'package:legado_core/src/js/java_host.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// 宿主函数可以返回 `Future`。
///
/// 原版 Kotlin 的 `java.ajax` 是阻塞式网络请求；Dart 侧只能异步发请求，
/// 所以解释器必须能在调用点把 `Future` 解包成最终结果——否则书源里
/// `var html = java.ajax(url)` 拿到的是一个 Future 对象，
/// `JSON.parse(html)` 会直接抛类型错误。
void main() {
  test('宿主函数返回 Future 时，脚本拿到的是最终结果', () async {
    final java = createJavaObject(
      ajax: (url) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return 'body:$url';
      },
    );

    final v = await run(
      'var r = java.ajax("/a"); r;',
      bindings: <String, Object?>{'java': java},
    );
    expect(v, 'body:/a');
  });

  test('Future 宿主函数可以参与字符串拼接与 JSON 解析', () async {
    final java = createJavaObject(
      ajax: (url) async => '{"url":"$url","n":7}',
    );

    final v = await run(
      'var o = JSON.parse(java.ajax("/b")); o.url + ":" + o.n;',
      bindings: <String, Object?>{'java': java},
    );
    expect(v, '/b:7');
  });

  test('Future 宿主函数抛出的异常能被 try/catch 抓住', () async {
    final java = createJavaObject(
      ajax: (url) async => throw StateError('boom'),
    );

    final v = await run(
      'try { java.ajax("/c"); } catch (e) { "caught:" + e.message; }',
      bindings: <String, Object?>{'java': java},
    );
    expect(v, startsWith('caught:'));
  });

  test('数组回调可以是异步的宿主函数', () async {
    final v = await run(
      'var out = []; [1,2,3].map(function (x) { return x * 2; }); '
      'var r = [1,2,3].map(function (x) { return java.fetch(x); }); '
      'r.join(",");',
      bindings: <String, Object?>{
        'java': createJavaObject(
          extraMethods: <String, Object? Function(List<Object?>)>{
            'fetch': (args) async {
              await Future<void>.delayed(const Duration(milliseconds: 1));
              return 'n${args.first}';
            },
          },
        ),
      },
    );
    expect(v, 'n1,n2,n3');
  });

  test('异步回调的 filter / sort 也能拿到最终值', () async {
    final java = createJavaObject(
      extraMethods: <String, Object? Function(List<Object?>)>{
        'double': (args) async => (args.first! as num) * 2,
      },
    );

    final filtered = await run(
      '[1,2,3,4].filter(function (x) { return java.double(x) > 4; }).join(",");',
      bindings: <String, Object?>{'java': java},
    );
    expect(filtered, '3,4');

    final sorted = await run(
      '[3,1,2].sort(function (a, b) { return java.double(a) - java.double(b); }).join(",");',
      bindings: <String, Object?>{'java': java},
    );
    expect(sorted, '1,2,3');
  });
}
