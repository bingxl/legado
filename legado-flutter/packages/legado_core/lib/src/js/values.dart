import 'dart:collection';

import 'js_exception.dart';

/// JS 值转换与几个宿主值包装类型。
///
/// 值模型刻意选成 Dart 原生类型，方便 bindings 直接传进传出：
/// `null`（同时代表 undefined）/ `bool` / `num` / `String` /
/// `List<Object?>` / `Map<String, Object?>`。

/// JS 的 `Number.toString()` 语义（整数不带 `.0`）。
String numToJsString(num n) {
  if (n is int) return n.toString();
  final d = n.toDouble();
  if (d.isNaN) return 'NaN';
  if (d.isInfinite) return d > 0 ? 'Infinity' : '-Infinity';
  if (d == 0) return '0';
  if (d == d.truncateToDouble() && d.abs() < 1e21) {
    return d.truncate().toString();
  }
  return d.toString();
}

/// ToPrimitive（简化版）：数组转成逗号拼接，普通对象转成 `[object Object]`。
Object? jsToPrimitive(Object? v) {
  if (v is List) return jsToString(v);
  if (v is Map) return '[object Object]';
  return v;
}

String jsToString(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) return numToJsString(v);
  if (v is String) return v;
  if (v is List) {
    return v.map((e) => e == null ? '' : jsToString(e)).join(',');
  }
  if (v is Map) return '[object Object]';
  if (v is JsRegExp) return v.toString();
  if (v is JsDate) return v.toString();
  if (v is JsHostObject) return '[object Object]';
  if (v is JsCallable) {
    final n = v.name;
    return n.isEmpty ? 'function () { [native code] }' : 'function $n() { [native code] }';
  }
  return v.toString();
}

num jsToNumber(Object? v) {
  if (v == null) return 0;
  if (v is num) return v;
  if (v is bool) return v ? 1 : 0;
  if (v is String) return stringToNumber(v);
  if (v is List) return stringToNumber(jsToString(v));
  if (v is JsDate) return v.millisecondsSinceEpoch;
  return double.nan;
}

/// JS 的字符串转数字：空串是 0，支持 0x/0b/0o、Infinity，其余整串匹配才有效。
num stringToNumber(String s) {
  final t = s.trim();
  if (t.isEmpty) return 0;
  if (t == 'Infinity' || t == '+Infinity') return double.infinity;
  if (t == '-Infinity') return double.negativeInfinity;
  final lower = t.toLowerCase();
  if (lower.startsWith('0x')) {
    final v = int.tryParse(t.substring(2), radix: 16);
    return v ?? double.nan;
  }
  if (lower.startsWith('0b')) {
    final v = int.tryParse(t.substring(2), radix: 2);
    return v ?? double.nan;
  }
  if (lower.startsWith('0o')) {
    final v = int.tryParse(t.substring(2), radix: 8);
    return v ?? double.nan;
  }
  final asInt = int.tryParse(t);
  if (asInt != null) return asInt;
  final asDouble = double.tryParse(t);
  if (asDouble != null) return asDouble;
  return double.nan;
}

bool jsToBoolean(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  return true;
}

String jsTypeOf(Object? v) {
  if (v == null) return 'undefined';
  if (v is bool) return 'boolean';
  if (v is num) return 'number';
  if (v is String) return 'string';
  if (v is JsCallable) return 'function';
  if (v is Function) return 'function';
  return 'object';
}

bool jsStrictEquals(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a == null || b == null) return a == null && b == null;
  if (a is String && b is String) return a == b;
  if (a is bool && b is bool) return a == b;
  if (a is List || a is Map) return identical(a, b);
  if (a is JsRegExp || a is JsDate || a is JsHostObject) return identical(a, b);
  return identical(a, b);
}

bool jsLooseEquals(Object? a, Object? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  if (a is num && b is num) return a == b;
  if (a is String && b is String) return a == b;
  if (a is bool && b is bool) return a == b;
  if (a is num && b is String) return a == stringToNumber(b);
  if (a is String && b is num) return stringToNumber(a) == b;
  if (a is bool) return jsLooseEquals(a ? 1 : 0, b);
  if (b is bool) return jsLooseEquals(a, b ? 1 : 0);
  final aObj = a is List || a is Map || a is JsHostObject;
  final bObj = b is List || b is Map || b is JsHostObject;
  if (aObj && !bObj) return jsLooseEquals(jsToPrimitive(a), b);
  if (bObj && !aObj) return jsLooseEquals(a, jsToPrimitive(b));
  return identical(a, b);
}

/// 原生/脚本函数的公共基类。放在 values.dart 是为了让宿主桥接
/// （java 对象的每个方法）不必依赖解释器实现细节。
abstract class JsCallable {
  String get name;

  Object? call(List<Object?> args, Object? thisArg);

  /// `new fn()`。默认当成普通调用后返回一个空对象。
  Object? construct(List<Object?> args) => call(args, null);

  /// 解释器唯一的调用入口。
  ///
  /// [call] 的返回值允许是 `Future`：宿主函数（如 `java.ajax`）要发网络请求，
  /// 只能异步返回。解释器在这里统一解包，脚本侧仍然是同步语义——
  /// `var html = java.ajax(url)` 拿到的是响应文本，不是 Future 对象。
  Future<Object?> callAsync(List<Object?> args, Object? thisArg) async {
    final r = call(args, thisArg);
    return r is Future ? await r : r;
  }

  /// 异步构造入口，语义同 [callAsync]。
  Future<Object?> constructAsync(List<Object?> args) async {
    final r = construct(args);
    return r is Future ? await r : r;
  }
}

/// 用 Dart 闭包实现的函数。bindings 里的 Dart 函数会被包装成它。
class NativeFunction extends JsCallable {
  NativeFunction(this.name, this.fn, {this.constructFn});

  @override
  final String name;

  final Object? Function(List<Object?> args, Object? thisArg) fn;
  final Object? Function(List<Object?> args)? constructFn;

  @override
  Object? call(List<Object?> args, Object? thisArg) => fn(args, thisArg);

  @override
  Object? construct(List<Object?> args) {
    final cf = constructFn;
    if (cf != null) return cf(args);
    return call(args, null);
  }
}

/// 宿主对象：`java` 就是它的实例。方法是同步的 Dart 闭包。
class JsHostObject extends JsCallable {
  JsHostObject({
    this.label,
    Map<String, Object?>? props,
    Map<String, Object? Function(List<Object?>)>? methods,
    this.callFn,
    this.constructFn,
  })  : props = props ?? <String, Object?>{},
        methods = methods ?? <String, Object? Function(List<Object?>)>{};

  /// 展示名（如 `java`、`Math`），同时作为 instanceof 判定依据。
  final String? label;
  final Map<String, Object?> props;
  final Map<String, Object? Function(List<Object?>)> methods;
  final Object? Function(List<Object?> args, Object? thisArg)? callFn;
  final Object? Function(List<Object?> args)? constructFn;

  @override
  String get name => label ?? '';

  @override
  Object? call(List<Object?> args, Object? thisArg) {
    final f = callFn;
    if (f == null) {
      throw JsException('TypeError: ${label ?? '该对象'} 不是函数');
    }
    return f(args, thisArg);
  }

  @override
  Object? construct(List<Object?> args) {
    final f = constructFn;
    if (f == null) return call(args, null);
    return f(args);
  }

  Object? getProperty(String key) {
    if (props.containsKey(key)) return props[key];
    final m = methods[key];
    if (m != null) return NativeFunction(key, (args, _) => m(args));
    return null;
  }

  bool hasProperty(String key) => props.containsKey(key) || methods.containsKey(key);

  void setProperty(String key, Object? value) {
    methods.remove(key);
    props[key] = value;
  }

  List<String> ownKeys() => [...props.keys, ...methods.keys];
}

/// 带附加属性的数组：正则 `exec`/`match` 的结果需要 `m.index`、`m.input`，
/// 但 Dart 的 List 不能挂属性，所以用这个兼容 List 的包装。
class JsArray extends ListBase<Object?> {
  JsArray([List<Object?>? items]) : _items = items ?? <Object?>[];

  final List<Object?> _items;
  final Map<String, Object?> props = <String, Object?>{};

  @override
  int get length => _items.length;

  @override
  set length(int value) {
    if (value < _items.length) {
      _items.removeRange(value, _items.length);
    } else {
      while (_items.length < value) {
        _items.add(null);
      }
    }
  }

  @override
  Object? operator [](int index) => _items[index];

  @override
  void operator []=(int index, Object? value) => _items[index] = value;
}

/// JS 正则。`g` 标志下 `lastIndex` 会在 exec 之间保留，书源里偶有依赖。
class JsRegExp {
  JsRegExp(this.source, this.flags) : _re = _compile(source, flags);

  factory JsRegExp.fromPattern(String pattern, [String flags = '']) {
    if (pattern.startsWith('/')) {
      final lastSlash = pattern.lastIndexOf('/');
      if (lastSlash > 0) {
        return JsRegExp(pattern.substring(1, lastSlash), pattern.substring(lastSlash + 1));
      }
    }
    return JsRegExp(pattern, flags);
  }

  final String source;
  final String flags;
  final RegExp _re;

  /// 上一次匹配结束位置，仅 global/sticky 时使用。
  int lastIndex = 0;

  RegExp get regExp => _re;

  bool get global => flags.contains('g');
  bool get ignoreCase => flags.contains('i');
  bool get multiline => flags.contains('m');
  bool get sticky => flags.contains('y');

  void resetLastIndex() => lastIndex = 0;

  static RegExp _compile(String source, String flags) {
    try {
      return RegExp(
        source,
        caseSensitive: !flags.contains('i'),
        multiLine: flags.contains('m'),
        dotAll: flags.contains('s'),
        unicode: flags.contains('u'),
      );
    } on FormatException catch (e) {
      throw JsException('非法正则 /$source/$flags：${e.message}', isSyntax: true);
    }
  }

  @override
  String toString() => '/$source/$flags';
}

/// JS Date 的包装。内部统一存毫秒。
class JsDate {
  JsDate(num ms) : _ms = ms.isFinite ? ms.toInt() : null;

  JsDate.now() : _ms = DateTime.now().millisecondsSinceEpoch;

  factory JsDate.fromDateTime(DateTime dt) => JsDate(dt.millisecondsSinceEpoch);

  final int? _ms;

  bool get isValid => _ms != null;

  int get millisecondsSinceEpoch => _ms ?? 0;

  DateTime get _local => DateTime.fromMillisecondsSinceEpoch(_ms ?? 0);

  DateTime get _utc => DateTime.fromMillisecondsSinceEpoch(_ms ?? 0, isUtc: true);

  int getFullYear() => _local.year;

  int getMonth() => _local.month - 1;

  int getDate() => _local.day;

  int getDay() => _local.weekday % 7;

  int getHours() => _local.hour;

  int getMinutes() => _local.minute;

  int getSeconds() => _local.second;

  int getMilliseconds() => _local.millisecond;

  int getUTCFullYear() => _utc.year;

  int getUTCMonth() => _utc.month - 1;

  int getUTCDate() => _utc.day;

  int getUTCHours() => _utc.hour;

  int getTime() => millisecondsSinceEpoch;

  String toISOString() {
    if (!isValid) return 'Invalid Date';
    final d = _utc;
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}'
        'T${two(d.hour)}:${two(d.minute)}:${two(d.second)}.${three(d.millisecond)}Z';
  }

  @override
  String toString() {
    if (!isValid) return 'Invalid Date';
    return _local.toString();
  }
}

/// 取 JS 值在 Dart 侧的「可读形式」，用于日志与错误信息。
String describeJsValue(Object? v) {
  if (v == null) return 'undefined';
  if (v is String) return '"$v"';
  if (v is List) return 'Array(${v.length})';
  if (v is Map) return 'Object';
  if (v is JsCallable) return 'function ${v.name}';
  return jsToString(v);
}
