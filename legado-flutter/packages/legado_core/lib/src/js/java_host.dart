import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'js_exception.dart';
import 'values.dart';

/// 构造书源脚本里的 `java` 对象。
///
/// 语义对齐 Kotlin 侧 `AnalyzeRule` + `JsExtensions`：
/// - 纯计算能力（base64/md5/hex/时间/编码/html 去标签）这里直接实现；
/// - 依赖网络与规则层的（`ajax`/`get`/`post`/`connect`/`getString`/
///   `getElements`/`getList`）通过回调注入，回调未注入时给出清晰报错，
///   而不是静默返回 null 让书源作者抓瞎。
///
/// 规则层的典型接法：
/// ```dart
/// final java = createJavaObject(
///   ajax: (url) => net.fetch(url),
///   getString: (rule) => analyzeRule.getString(rule),
///   onLog: logger.info,
/// );
/// engine.eval(script, bindings: {'java': java, 'result': content});
/// ```
JsHostObject createJavaObject({
  Object? Function(String url)? ajax,
  Object? Function(String url)? get,
  Object? Function(String url, Object? body, Object? headers)? post,
  Object? Function(String url, Object? body, Object? headers)? connect,
  Object? Function(List<String> urls)? ajaxAll,
  Object? Function(String rule)? getString,
  Object? Function(String rule)? getElements,
  Object? Function(String rule)? getList,
  Object? Function(String? msg)? toast,
  Object? Function(String? msg)? longToast,
  void Function(String msg)? onLog,
  /// `java.getCookie(url[, key])`：读 CookieStore。返回 `''` 表示没有。
  String? Function(String url, String? key)? getCookie,
  /// `java.startBrowser(url, title)`：打开内置浏览器，不等结果（对齐
  /// `SourceVerificationHelp.startBrowser`）。
  Object? Function(String url, String title)? startBrowser,
  /// `java.startBrowserAwait(url, title[, refetchAfterSuccess])`：打开内置浏览器
  /// 并**阻塞等待**用户过验证，返回 `StrResponse`（对齐同名 Kotlin 扩展）。
  Object? Function(String url, String title, bool refetchAfterSuccess)?
  startBrowserAwait,
  /// `java.getVerificationCode(imageUrl)`：弹图片验证码对话框，返回用户输入的串。
  Object? Function(String imageUrl)? getVerificationCode,
  /// 繁简转换（`t2s` 第二参为 true，`s2t` 为 false）。未注入时原样返回。
  String Function(String text, {required bool toSimplified})? chineseConvert,
  Map<String, Object?>? variables,
  Map<String, Object?>? props,
  Map<String, Object? Function(List<Object?>)>? extraMethods,
  String androidId = '',
}) {
  final store = variables ?? <String, Object?>{};

  JsHostObject host() {
    return JsHostObject(
      label: 'java',
      props: {
        ...?props,
        'androidId': androidId,
      },
      methods: {
        'ajax': (args) {
          if (ajax == null) {
            throw JsException('java.ajax 未接入网络层（rules 层需通过 createJavaObject(ajax:) 注入）');
          }
          final url = _firstUrl(args);
          return ajax(url);
        },
        'post': (args) {
          if (post == null) {
            throw JsException('java.post 未接入网络层（rules 层需通过 createJavaObject(post:) 注入）');
          }
          final url = args.isEmpty ? '' : jsToString(args[0]);
          final body = args.length > 1 ? args[1] : null;
          final headers = args.length > 2 ? args[2] : null;
          return post(url, body, headers);
        },
        'connect': (args) {
          if (connect == null) {
            throw JsException('java.connect 未接入网络层（rules 层需通过 createJavaObject(connect:) 注入）');
          }
          final url = _firstUrl(args);
          final body = args.length > 1 ? args[1] : null;
          final headers = args.length > 2 ? args[2] : null;
          return connect(url, body, headers);
        },
        'getString': (args) {
          if (getString == null) {
            throw JsException('java.getString 需要规则层注入（按规则求值，不是读变量）');
          }
          return getString(args.isEmpty ? '' : jsToString(args[0]));
        },
        'ajaxAll': (args) {
          if (ajaxAll == null) {
            throw JsException('java.ajaxAll 未接入网络层');
          }
          final raw = args.isEmpty ? null : args[0];
          final urls = raw is List
              ? [for (final e in raw) jsToString(e)]
              : <String>[if (raw != null) jsToString(raw)];
          return ajaxAll(urls);
        },
        'startBrowser': (args) {
          if (startBrowser == null) {
            throw JsException(
              'java.startBrowser 需要宿主提供内置浏览器（App 端注册验证处理器）',
            );
          }
          final url = args.isEmpty ? '' : jsToString(args[0]);
          final title = args.length > 1 ? jsToString(args[1]) : '';
          return startBrowser(url, title);
        },
        'startBrowserAwait': (args) {
          if (startBrowserAwait == null) {
            throw JsException(
              'java.startBrowserAwait 需要宿主提供内置浏览器（App 端注册验证处理器）',
            );
          }
          final url = args.isEmpty ? '' : jsToString(args[0]);
          final title = args.length > 1 ? jsToString(args[1]) : '';
          // 第三参缺省为 true：与 Kotlin 的 `refetchAfterSuccess: Boolean = true` 一致。
          final refetch = args.length > 2 && args[2] != null
              ? jsToBoolean(args[2])
              : true;
          return startBrowserAwait(url, title, refetch);
        },
        'getVerificationCode': (args) {
          if (getVerificationCode == null) {
            throw JsException(
              'java.getVerificationCode 需要宿主支持图片验证码输入（App 端注册）',
            );
          }
          return getVerificationCode(args.isEmpty ? '' : jsToString(args[0]));
        },
        'getCookie': (args) {
          if (getCookie == null) {
            throw JsException('java.getCookie 需要注入 CookieStore');
          }
          final url = args.isEmpty ? '' : jsToString(args[0]);
          final key = args.length > 1 && args[1] != null
              ? jsToString(args[1])
              : null;
          return getCookie(url, key) ?? '';
        },
        // 繁简转换：原版由 quick.transfer 的完整字表实现。这里没接字表时
        // 原样返回 —— 书源拿它多用于标题/搜索词的字体归一，
        // 退化成「不转换」比抛 ReferenceError 把整条规则打断要好。
        't2s': (args) =>
            chineseConvert?.call(_argStr(args), toSimplified: true) ??
            _argStr(args),
        's2t': (args) =>
            chineseConvert?.call(_argStr(args), toSimplified: false) ??
            _argStr(args),
        'getElements': (args) {
          if (getElements == null) {
            throw JsException('java.getElements 需要规则层注入');
          }
          return getElements(args.isEmpty ? '' : jsToString(args[0]));
        },
        'getList': (args) {
          if (getList == null) {
            throw JsException('java.getList 需要规则层注入');
          }
          return getList(args.isEmpty ? '' : jsToString(args[0]));
        },
        'base64Encode': (args) {
          final s = args.isEmpty ? '' : jsToString(args[0]);
          return base64Encode(utf8.encode(s));
        },
        'base64Decode': (args) {
          final s = args.isEmpty ? '' : jsToString(args[0]);
          try {
            return _decodeBase64Lenient(s);
          } on FormatException {
            return '';
          }
        },
        'base64DecodeToByteArray': (args) {
          final s = args.isEmpty ? '' : jsToString(args[0]);
          try {
            return _decodeBase64Lenient(s).codeUnits;
          } on FormatException {
            return null;
          }
        },
        'md5Encode': (args) => md5.convert(utf8.encode(_argStr(args))).toString(),
        'md5Encode16': (args) {
          final hex = md5.convert(utf8.encode(_argStr(args))).toString();
          return hex.substring(8, 24);
        },
        'hexEncodeToString': (args) {
          final bytes = utf8.encode(_argStr(args));
          return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        },
        'hexDecodeToByteArray': (args) => _hexDecodeToBytes(_argStr(args)),
        'hexDecodeToString': (args) {
          final bytes = _hexDecodeToBytes(_argStr(args));
          if (bytes == null) return null;
          return utf8.decode(bytes, allowMalformed: true);
        },
        'strToBytes': (args) {
          final s = _argStr(args);
          final enc = args.length > 1 ? jsToString(args[1]).toLowerCase() : 'utf-8';
          if (enc.contains('gbk') || enc.contains('gb2312')) {
            return _latin1Bytes(s);
          }
          return utf8.encode(s);
        },
        'bytesToStr': (args) {
          final list = args.isEmpty ? null : args[0];
          final enc = args.length > 1 ? jsToString(args[1]).toLowerCase() : 'utf-8';
          final bytes = _toBytes(list);
          if (bytes == null) return '';
          if (enc.contains('gbk') || enc.contains('gb2312')) {
            return String.fromCharCodes(bytes);
          }
          return utf8.decode(bytes, allowMalformed: true);
        },
        'timeFormat': (args) {
          final ms = args.isEmpty ? DateTime.now().millisecondsSinceEpoch : jsToNumber(args[0]).toInt();
          final dt = DateTime.fromMillisecondsSinceEpoch(ms);
          return '${dt.year.toString().padLeft(4, '0')}/${_two(dt.month)}/${_two(dt.day)} '
              '${_two(dt.hour)}:${_two(dt.minute)}';
        },
        'timeFormatUTC': (args) {
          final ms = args.isEmpty ? 0 : jsToNumber(args[0]).toInt();
          final format = args.length > 1 ? jsToString(args[1]) : 'yyyy/MM/dd HH:mm';
          final sh = args.length > 2 ? jsToNumber(args[2]).toInt() : 0;
          final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(Duration(hours: sh));
          return _formatDateTime(dt, format);
        },
        'encodeURI': (args) {
          final s = _argStr(args);
          final enc = args.length > 1 ? jsToString(args[1]) : 'UTF-8';
          return _urlEncode(s, enc);
        },
        'htmlFormat': (args) => _htmlFormat(_argStr(args)),
        'log': (args) {
          final msg = args.map(jsToString).join(' ');
          onLog?.call(msg);
          return null;
        },
        'toast': (args) {
          toast?.call(args.isEmpty ? null : jsToString(args[0]));
          return null;
        },
        'longToast': (args) {
          longToast?.call(args.isEmpty ? null : jsToString(args[0]));
          return null;
        },
        'put': (args) {
          final key = args.isEmpty ? '' : jsToString(args[0]);
          store[key] = args.length > 1 ? args[1] : null;
          return '';
        },
        'get': (args) {
          // Kotlin 里 java.get(url, headers) 是网络请求，java.get(key) 是读变量。
          if (args.length >= 2) {
            if (get == null) {
              throw JsException('java.get(url, headers) 未接入网络层（rules 层需通过 createJavaObject(get:) 注入）');
            }
            return get(_firstUrl(args));
          }
          return store[args.isEmpty ? '' : jsToString(args[0])];
        },
        'getVariable': (args) => store[args.isEmpty ? '' : jsToString(args[0])],
        'putVariable': (args) {
          final key = args.isEmpty ? '' : jsToString(args[0]);
          store[key] = args.length > 1 ? args[1] : null;
          return null;
        },
        ...?extraMethods,
      },
    );
  }

  return host();
}

String _argStr(List<Object?> args) => args.isEmpty ? '' : jsToString(args[0]);

String _firstUrl(List<Object?> args) {
  if (args.isEmpty) return '';
  final v = args[0];
  if (v is List) return v.isEmpty ? '' : jsToString(v.first);
  return jsToString(v);
}

String _two(int n) => n.toString().padLeft(2, '0');

String _formatDateTime(DateTime dt, String format) {
  var out = format;
  out = out.replaceAll('yyyy', dt.year.toString().padLeft(4, '0'));
  out = out.replaceAll('MM', _two(dt.month));
  out = out.replaceAll('dd', _two(dt.day));
  out = out.replaceAll('HH', _two(dt.hour));
  out = out.replaceAll('mm', _two(dt.minute));
  out = out.replaceAll('ss', _two(dt.second));
  return out;
}

String _decodeBase64Lenient(String s) {
  var t = s.trim().replaceAll(RegExp(r'\s'), '');
  t = t.replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  return utf8.decode(base64Decode(t), allowMalformed: true);
}

List<int>? _hexDecodeToBytes(String hex) {
  var h = hex.trim();
  if (h.length.isOdd) h = '0$h';
  final out = <int>[];
  for (var i = 0; i < h.length; i += 2) {
    final b = int.tryParse(h.substring(i, i + 2), radix: 16);
    if (b == null) return null;
    out.add(b);
  }
  return out;
}

List<int>? _toBytes(Object? v) {
  if (v is List) {
    return v.map((e) => jsToNumber(e).toInt() & 0xFF).toList();
  }
  if (v is String) return utf8.encode(v);
  return null;
}

List<int> _latin1Bytes(String s) => s.codeUnits.map((c) => c & 0xFF).toList();

String _urlEncode(String s, String charset) {
  // URLEncoder 语义：空格变 '+'，其他按 UTF-8 百分号编码。
  final encoded = Uri.encodeComponent(s);
  return encoded.replaceAll('%20', '+');
}

String _htmlFormat(String html) {
  var s = html;
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
  return s.trim();
}
