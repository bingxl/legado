import 'values.dart';

/// Kotlin `StrResponse` 的替身，给 `java.get` / `java.startBrowserAwait` 这类
/// 「返回一个响应对象」的桥用。
///
/// 为什么要这么绕：原版 `StrResponse` **同时**有 `body` 属性和 `body()` 方法
/// （Kotlin 里 `var body: String?` + `fun body()`），书源里两种写法都在用：
///
/// ```js
/// result = java.startBrowserAwait(url, "验证").body();   // 方法
/// result = "" + java.startBrowserAwait(url, "验证").body; // 属性（拼字符串）
/// ```
///
/// JS 一个键只能放一个值，所以把 `body` 做成**函数**，再用 [JsCallable.stringForm]
/// 让它在被字符串化时给出正文。这样 `.body()`、`+ ''`、`String(.body)`
/// 三种写法都成立；唯一不成立的是 `.body.length` / `.body.match(...)` 这类
/// 把函数当字符串用的写法 —— 那样本来也拿不到正文。
JsHostObject strResponseObject(
  String body, {
  String url = '',
  int statusCode = 200,
}) {
  NativeFunction bodyFn() => NativeFunction(
    'body',
    (args, _) => body,
    stringForm: body,
  );

  return JsHostObject(
    label: 'StrResponse',
    // 整个对象字符串化也给正文：`"" + res` 这种写法同样常见。
    stringForm: body,
    props: {
      'body': bodyFn(),
      'url': url,
      'statusCode': statusCode,
    },
    methods: {
      'toString': (args) => body,
    },
  );
}
