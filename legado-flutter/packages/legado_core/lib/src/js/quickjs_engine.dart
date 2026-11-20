import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:native_synchronization/mailbox.dart';
import 'package:native_synchronization/sendable.dart';
import 'package:quickjs_runtime/quickjs_runtime.dart';

import 'js_engine.dart';
import 'js_exception.dart';
import 'values.dart';

/// 基于 QuickJS 的书源脚本引擎（真 JS，不是子集解释器）。
///
/// 为什么要这么绕：QuickJS 的宿主回调是**同步**的，而书源里的 `java.ajax`
/// 只能异步（Dart 没有阻塞 IO）。所以：
///
/// - 每段脚本在一个独立的 worker isolate 里跑（QuickJS 与 Dart 的
///   `NativeCallable` 都要求同线程）；
/// - 脚本调用宿主函数时，worker 在 FFI 回调里把请求发给主 isolate，
///   然后用 [Mailbox] **阻塞住自己**等回包（主 isolate 的事件循环照常转，
///   网络请求能正常 await）；
/// - 主 isolate 拿到结果后把 JSON 塞回 Mailbox，worker 解阻塞继续跑。
///
/// 每个 worker 只跑一段脚本，所以某个书源脚本死循环也不会卡住 UI
/// （Dart 解释器版本是直接跑在主 isolate 上的，会卡）。
///
/// 并发：引擎维护一个 worker 池。`java.getString` 这类回调会在宿主回调里
/// 再次触发 `eval`（规则层用同一个引擎解析子规则），此时外层 worker 正被
/// 阻塞着，必须另起一个 —— 见 [_inHostCallback] 的 Zone 标记。
///
/// 脚本用「函数里直接 eval」执行（见 [_Prelude] 的 `__legadoRun`），
/// 这样 `var`/`let`/`const` 不会泄漏到 globalThis；递归深度受 worker
/// 线程剩余栈量限制（桌面实测 ~160 层），远高于书源脚本的实际需要。
class QuickJsEngine implements JsEngine {
  QuickJsEngine({this.onLog, this.maxWorkers = 32});

  /// `console.log` / `print` 的输出通道。默认丢弃。
  final void Function(String level, String msg)? onLog;

  /// 池里最多保留多少个 worker。全部在忙时还会按需多开（嵌套求值不能排队，
  /// 否则会死锁），这个上限只约束「排队等空闲 worker」的并发。
  final int maxWorkers;

  final List<_Worker> _idle = <_Worker>[];
  final List<_Worker> _workers = <_Worker>[];
  final List<Completer<_Worker>> _waiters = <Completer<_Worker>>[];
  final Map<int, _EvalSession> _sessions = <int, _EvalSession>{};

  int _nextEvalId = 1;
  int _spawning = 0;
  bool _disposed = false;

  /// 标记「当前正处在某个宿主回调里」。嵌套 `eval` 必须另开 worker。
  static final Object _inHostCallback = Object();

  @override
  Future<Object?> eval(String script, {Map<String, Object?> bindings = const {}}) async {
    if (_disposed) throw StateError('QuickJsEngine 已释放');
    final nested = Zone.current[_inHostCallback] == true;

    final session = _EvalSession();
    final spec = <String, Object?>{};
    bindings.forEach((k, v) => spec[k] = session.encode(v));

    final evalId = _nextEvalId++;
    _sessions[evalId] = session;
    final worker = await _acquire(nested: nested);
    try {
      final reply = await worker.run(evalId, script, spec);
      if (reply['ok'] != true) {
        throw _errorOf(reply, script);
      }
      final value = reply['value'] as String?;
      if (value == null || value == 'undefined') return null;
      final decoded = jsonDecode(value);
      // __legadoResult 把 NaN / Infinity 打成了单键对象（JSON 表达不了它们）。
      if (decoded is Map && decoded.length == 1 && decoded['__legadoNum'] is String) {
        switch (decoded['__legadoNum'] as String) {
          case 'NaN':
            return double.nan;
          case 'Infinity':
            return double.infinity;
          case '-Infinity':
            return double.negativeInfinity;
        }
      }
      return decoded;
    } finally {
      _sessions.remove(evalId);
      _release(worker);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _waiters) {
      if (!c.isCompleted) {
        c.completeError(StateError('QuickJsEngine 已释放'));
      }
    }
    _waiters.clear();
    for (final w in _workers) {
      w.destroy();
    }
    _workers.clear();
    _idle.clear();
    _sessions.clear();
  }

  // ---- worker 池 ---------------------------------------------------------

  Future<_Worker> _acquire({required bool nested}) async {
    if (_idle.isNotEmpty) return _idle.removeLast();
    // 嵌套求值时外层 worker 正阻塞在宿主回调里，排队必然死锁，只能新开。
    if (nested || _waiters.isEmpty && _workers.length + _spawning < maxWorkers) {
      _spawning++;
      try {
        final worker = await _spawn();
        _workers.add(worker);
        return worker;
      } finally {
        _spawning--;
      }
    }
    final waiter = Completer<_Worker>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release(_Worker worker) {
    if (_disposed || worker.dead) return;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(worker);
      return;
    }
    _idle.add(worker);
  }

  Future<_Worker> _spawn() async {
    final events = ReceivePort();
    final mailbox = Mailbox();
    final worker = _Worker(mailbox: mailbox, events: events);
    worker.ready = Completer<SendPort>();

    try {
      worker.isolate = await Isolate.spawn(
        _workerEntry,
        <String, Object?>{
          'events': events.sendPort,
          'mailbox': mailbox.asSendable,
        },
        debugName: 'legado-quickjs',
        onError: events.sendPort,
        onExit: events.sendPort,
      );
    } catch (e) {
      events.close();
      mailbox.close();
      throw JsEngineUnavailable('无法启动 QuickJS worker: $e', e);
    }

    events.listen((dynamic message) => _onMessage(worker, message));
    try {
      final port = await worker.ready!.future;
      worker.commands = port;
      return worker;
    } on JsEngineUnavailable {
      worker.destroy();
      rethrow;
    }
  }

  // ---- worker 消息 -------------------------------------------------------

  void _onMessage(_Worker worker, dynamic raw) {
    if (worker.dead) return;
    if (raw is! Map) {
      // Isolate 的 onError（List）/ onExit（null）也走这个端口
      worker.dead = true;
      _failPending(worker, 'QuickJS worker 异常退出: $raw');
      return;
    }
    final message = raw as Map<Object?, Object?>;
    switch (message['t']) {
      case 'ready':
        final ready = worker.ready;
        if (ready != null && !ready.isCompleted) {
          ready.complete(message['port'] as SendPort);
        }
        break;
      case 'failed':
        final error = message['error']?.toString() ?? '未知错误';
        final stack = message['stack']?.toString();
        final ready = worker.ready;
        if (ready != null && !ready.isCompleted) {
          ready.completeError(
            JsEngineUnavailable('QuickJS 初始化失败: $error', stack),
          );
        }
        worker.dead = true;
        _failPending(worker, 'QuickJS 初始化失败: $error');
        break;
      case 'call':
        unawaited(_handleHostCall(worker, message));
        break;
      case 'done':
        final pending = worker.pending;
        worker.pending = null;
        if (pending != null && !pending.isCompleted) {
          pending.complete(message);
        }
        break;
    }
  }

  void _failPending(_Worker worker, String reason) {
    final pending = worker.pending;
    worker.pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError(reason));
    }
  }

  /// 处理 worker 发来的宿主调用请求。
  ///
  /// 这里的 `await` 会真的等（网络请求），worker 侧则阻塞在 Mailbox 上。
  Future<void> _handleHostCall(_Worker worker, Map<Object?, Object?> message) async {
    final evalId = message['evalId'] as int;
    final session = _sessions[evalId];
    final reply = <String, Object?>{};
    try {
      final payload = jsonDecode(message['args'] as String);
      final list = payload is List ? payload : <Object?>[payload];
      final callId = list.isEmpty ? -1 : (list.first as num).toInt();
      final args = list.length > 1 ? list.sublist(1) : const <Object?>[];

      if (callId == _logCallId) {
        onLog?.call('${args.isEmpty ? 'log' : args[0]}', args.length > 1 ? '${args[1]}' : '');
        reply['ok'] = true;
        reply['v'] = null;
      } else {
        final fn = session?.callables[callId];
        if (fn == null) {
          throw JsException('宿主回调 $callId 已失效（脚本执行上下文已结束）');
        }
        final value = await runZoned(
          () => session!.invoke(fn, args),
          zoneValues: <Object?, Object?>{_inHostCallback: true},
        );
        reply['ok'] = true;
        reply['v'] = session!.encode(value);
      }
    } catch (e) {
      reply['ok'] = false;
      reply['e'] = _messageOf(e);
    }
    worker.reply(reply);
  }

  // ---- 错误 --------------------------------------------------------------

  JsException _errorOf(Map<Object?, Object?> reply, String script) {
    final text = reply['error']?.toString() ?? '脚本执行失败';
    // 脚本本身直接 eval，QuickJS 把它的源码记作 <input>，行号就是脚本行号。
    // 兜底再认 <eval>（旧包装方式）和其它源码名。
    final match = RegExp(r'<input>:(\d+)(?::(\d+))?').firstMatch(text) ??
        RegExp(r'<(?!legado_prelude)[^>\n]+>:(\d+)(?::(\d+))?')
            .firstMatch(text);
    // 脚本通过 eval 执行，eval 代码的第 1 行就是脚本第 1 行，无需偏移。
    final line = match == null ? null : int.tryParse(match.group(1)!);
    final column = match?.group(2) == null ? null : int.tryParse(match!.group(2)!);
    final firstLine = text.split('\n').first;
    final isError = RegExp(r'^\w*Error: ').hasMatch(firstLine);
    // `throw {code: 7}` / `throw "x"` 抛的不是 Error，JS_ToCString 只会给
    // "[object Object]"，补一句人话（和 Dart 解释器的提示一致）。
    final message = isError
        ? firstLine.replaceFirst(RegExp(r'^\w*Error: '), '')
        : '未捕获的异常: $firstLine';
    return JsException(
      _translate(message),
      line: line,
      column: column,
      sourceLine: line == null ? null : sourceLineOf(script, line),
      script: script,
      isSyntax: text.startsWith('SyntaxError'),
    );
  }

  String _translate(String message) {
    // 书源作者看到的是中文报错，这里只翻译最常见的几种，其余保留 QuickJS 原文。
    if (message == 'not a function') return '不是函数';
    final readOnly = RegExp(r"^'?([^']+)'? is read-only$").firstMatch(message);
    if (readOnly != null) return '常量 ${readOnly.group(1)} 不能重新赋值';
    final notDefined = RegExp(r'^([^ ]+) is not defined$').firstMatch(message);
    if (notDefined != null) return '变量 ${notDefined.group(1)} 未定义';
    final notFunction =
        RegExp(r'^([^ ]+) is not a function$').firstMatch(message);
    if (notFunction != null) return '${notFunction.group(1)} 不是函数';
    return message;
  }

  String _messageOf(Object e) {
    if (e is JsException) return e.message;
    final text = e.toString();
    return text.replaceFirst(RegExp(r'^\w*Exception: '), '');
  }
}

/// `console.log` 使用的保留回调 id。
const int _logCallId = -1;

/// 一段脚本的宿主回调表。
///
/// id 只在本次 `eval` 内有效：脚本里每个 Dart 函数/宿主对象方法都被编成一个
/// 编号，worker 把编号发回来，这里查表执行。宿主对象**返回**的宿主对象
/// （`java.connect(...).body()`）也会在同一个表里继续分配编号。
class _EvalSession {
  final Map<int, Object? Function(List<Object?>)> callables =
      <int, Object? Function(List<Object?>)>{};
  int _nextId = 1;

  int _register(Object? Function(List<Object?>) fn) {
    final id = _nextId++;
    callables[id] = fn;
    return id;
  }

  Future<Object?> invoke(Object? Function(List<Object?>) fn, List<Object?> args) async {
    final r = fn(args);
    return r is Future ? await r : r;
  }

  /// 把 Dart 值编成 worker 能还原的结构（JSON 里塞标记，见 [_Prelude]）。
  Object? encode(Object? value) {
    if (value == null || value is bool || value is num || value is String) return value;
    if (value is JsHostObject) return _encodeHostObject(value);
    if (value is JsCallable) {
      final id = _register((args) => value.call(args, null));
      return <String, Object?>{'t': 'f', 'i': id};
    }
    if (value is Function) {
      final id = _register((args) => _callDartFunction(value, args));
      return <String, Object?>{'t': 'f', 'i': id};
    }
    if (value is Map) {
      final map = <String, Object?>{};
      value.forEach((k, v) => map['$k'] = encode(v));
      return <String, Object?>{'t': 'm', 'v': map};
    }
    if (value is Iterable) {
      return <String, Object?>{
        't': 'a',
        'v': <Object?>[for (final e in value) encode(e)],
      };
    }
    // 兜底：DateTime / Uint8List 之类按 JS 的 String() 语义给字符串。
    return jsToString(value);
  }

  Map<String, Object?> _encodeHostObject(JsHostObject host) {
    final props = <String, Object?>{};
    host.props.forEach((k, v) => props[k] = encode(v));
    final methods = <String, Object?>{};
    host.methods.forEach((k, fn) => methods[k] = _register(fn));
    final callFn = host.callFn;
    final constructFn = host.constructFn;
    return <String, Object?>{
      't': 'o',
      'n': host.label,
      'i': callFn == null ? null : _register((args) => callFn(args, null)),
      'c': constructFn == null ? null : _register((args) => constructFn(args)),
      'p': props,
      'm': methods,
    };
  }

  Future<Object?> _callDartFunction(Function fn, List<Object?> args) async {
    Object? r;
    if (fn is Object? Function(List<Object?>)) {
      r = fn(args);
    } else if (fn is Object? Function()) {
      r = fn();
    } else {
      r = Function.apply(fn, args);
    }
    return r is Future ? await r : r;
  }
}

/// 一个跑 QuickJS 的 worker isolate。
class _Worker {
  _Worker({required this.mailbox, required this.events});

  final Mailbox mailbox;
  final ReceivePort events;
  Isolate? isolate;
  SendPort? commands;
  Completer<SendPort>? ready;
  Completer<Map<Object?, Object?>>? pending;
  bool dead = false;

  Future<Map<Object?, Object?>> run(
    int evalId,
    String script,
    Map<String, Object?> spec,
  ) {
    final completer = Completer<Map<Object?, Object?>>();
    pending = completer;
    commands!.send(<String, Object?>{
      't': 'eval',
      'id': evalId,
      'code': script,
      'spec': spec,
    });
    return completer.future;
  }

  /// 把宿主回调结果塞回 worker（worker 正阻塞在 `Mailbox.take()`）。
  void reply(Map<String, Object?> message) {
    if (dead) return;
    try {
      mailbox.put(Uint8List.fromList(utf8.encode(jsonEncode(message))));
    } on StateError {
      // worker 已经走了
    }
  }

  void destroy() {
    dead = true;
    // 先关 Mailbox：worker 若正阻塞在 take() 上会被唤醒并抛 StateError，
    // 之后 isolate 才能真的退出（原生阻塞中 kill 不会立刻生效）。
    try {
      mailbox.close();
    } catch (_) {}
    isolate?.kill(priority: Isolate.immediate);
    events.close();
  }
}

// ---- worker 侧 -----------------------------------------------------------

/// worker isolate 入口：建 QuickJS 运行时，然后逐条执行主 isolate 发来的脚本。
void _workerEntry(Map<String, Object?> args) {
  final events = args['events'] as SendPort;
  final mailbox = (args['mailbox']! as Sendable<Mailbox>).materialize();
  final inbox = ReceivePort();

  QuickjsRuntime runtime;
  try {
    runtime = QuickjsRuntime();
    runtime.registerHostFunction(_bridgeName, (String argsJson) {
      // [callId, ...args]：原样转发，主 isolate 负责解析
      events.send(<String, Object?>{
        't': 'call',
        'evalId': _currentEvalId,
        'args': argsJson,
      });
      return utf8.decode(mailbox.take());
    });
  } catch (e, st) {
    events.send(<String, Object?>{
      't': 'failed',
      'error': '$e',
      'stack': '$st',
    });
    inbox.close();
    return;
  }

  events.send(<String, Object?>{'t': 'ready', 'port': inbox.sendPort});

  inbox.listen((dynamic raw) {
    final message = raw as Map<Object?, Object?>;
    if (message['t'] != 'eval') return;
    final evalId = message['id'] as int;
    final code = message['code'] as String;
    final spec = message['spec'];
    _currentEvalId = evalId;
    final out = <String, Object?>{'t': 'done', 'id': evalId};
    try {
      runtime.setGlobal('__legadoSpec', spec);
      final preludeErr = <String?>[];
      runtime.eval(_Prelude.source, filename: '<legado_prelude>', errMsg: preludeErr);
      final preludeError = _firstError(preludeErr);
      if (preludeError != null) {
        out['ok'] = false;
        out['error'] = '绑定注入失败: $preludeError';
        events.send(out);
        return;
      }

      final err = <String?>[];
      // 脚本作为字符串交给 __legadoRun 里的**直接** eval：var/let/const 都留在
      // 那个函数的作用域里，不会变成 globalThis 上的（不可删除的）属性。
      // 直接 eval 的代码在 QuickJS 里记作 <input>，行号就是脚本行号。
      // 外层 __legadoResult 只做一件事：把 NaN / Infinity 标出来（JSON 存不下）。
      var value = runtime.eval(
        '__legadoResult(__legadoRun(${jsonEncode(code)}))',
        filename: '<legado_script>',
        errMsg: err,
      );
      var error = _firstError(err);

      // Dart 解释器允许顶层 `return`（真实 Rhino 不允许，但已有书源/用例这么写），
      // 这里兼容一下：语法错误恰好是顶层 return 就包成函数再跑一次。
      if (value == null && error != null && _isTopLevelReturn(error)) {
        err.clear();
        value = runtime.eval(
          '__legadoResult(__legadoRunFn(${jsonEncode(code)}))',
          filename: '<legado_script>',
          errMsg: err,
        );
        error = _firstError(err);
      }

      out['ok'] = error == null;
      out['value'] = value;
      if (error != null) out['error'] = error;
    } catch (e, st) {
      out['ok'] = false;
      out['error'] = 'QuickJS 执行异常: $e\n$st';
    }
    events.send(out);
  });
}

int _currentEvalId = 0;

String? _firstError(List<String?> err) =>
    err.isEmpty || err.first == null ? null : err.first;

bool _isTopLevelReturn(String error) {
  final lower = error.toLowerCase();
  return lower.contains('syntaxerror') &&
      lower.contains('return') &&
      lower.contains('function');
}

const String _bridgeName = '__legadoBridge';

/// 每次脚本执行前注入的 JS 前奏。
///
/// 它负责三件事：
/// 1. 定义 `__legadoHostCall`（宿主调用 + 错误还原）与 `decode`（把 Dart 编好的
///    结构还原成 JS 对象/函数）；
/// 2. 清掉上一次执行注入的全局变量，再用本次 bindings 覆盖；
/// 3. 补上 `console` / `print`（QuickJS 本身没有）。
abstract final class _Prelude {
  static const String source = r'''
(function () {
  var g = globalThis;
  // 一段脚本结束后它的 var / 函数声明会留在全局对象上。书源脚本是"一次求值"
  // 语义（Kotlin 侧每次都新建 context），所以下次执行前把上次新增的全局删掉。
  // 基线在第一次执行时快照，之后只删「不在基线里、也不是 __legado* 基础设施」的键。
  if (typeof g.__legadoResetGlobals === 'function') g.__legadoResetGlobals();
  if (typeof g.__legadoResetGlobals !== 'function') {
    g.__legadoResetGlobals = (function () {
      var base = {};
      for (var k in globalThis) base[k] = true;
      return function () {
        for (var name in globalThis) {
          if (base[name] === true) continue;
          if (name.indexOf('__legado') === 0) continue;
          try { delete globalThis[name]; } catch (e) {}
        }
      };
    })();
  }

  if (typeof g.__legadoDecode !== 'function') {
    g.__legadoMakeFn = function (id, ctorId, name) {
      var fn = function () {
        var args = Array.prototype.slice.call(arguments);
        if (ctorId !== null && ctorId !== undefined && new.target !== undefined) {
          return g.__legadoHostCall(ctorId, args);
        }
        return g.__legadoHostCall(id, args);
      };
      if (name) {
        try { Object.defineProperty(fn, 'name', { value: String(name) }); } catch (e) {}
      }
      return fn;
    };
    g.__legadoDecode = function (node) {
      if (node === null || typeof node !== 'object') return node;
      var t = node.t;
      if (t === 'a') {
        var arr = [];
        for (var i = 0; i < node.v.length; i++) arr.push(g.__legadoDecode(node.v[i]));
        return arr;
      }
      if (t === 'm') {
        var obj = {};
        for (var k in node.v) obj[k] = g.__legadoDecode(node.v[k]);
        return obj;
      }
      if (t === 'f') return g.__legadoMakeFn(node.i, null, node.n);
      if (t === 'o') {
        var target;
        if (node.i !== null && node.i !== undefined) {
          target = g.__legadoMakeFn(node.i, node.c, node.n);
        } else if (node.c !== null && node.c !== undefined) {
          target = g.__legadoMakeFn(null, node.c, node.n);
        } else {
          target = {};
        }
        for (var pk in node.p) target[pk] = g.__legadoDecode(node.p[pk]);
        for (var mk in node.m) target[mk] = g.__legadoMakeFn(node.m[mk], null, mk);
        return target;
      }
      return node;
    };
    g.__legadoHostCall = function (id, args) {
      var reply = g.__legadoBridge([id].concat(args));
      if (!reply || typeof reply !== 'object') {
        throw new Error('宿主回调没有返回结果');
      }
      if (reply.ok !== true) {
        throw new Error(reply.e === undefined || reply.e === null ? '宿主调用失败' : String(reply.e));
      }
      return g.__legadoDecode(reply.v);
    };
  }

  // console / print 每次都要补：上面的全局清理会把它们删掉。
  // 级别与 Dart 解释器保持一致（一律 info，warn/error 带前缀），
  // 免得换引擎后 App 里的日志看起来变了样。
  var log = function (prefix) {
    return function () {
      var text = Array.prototype.slice.call(arguments).map(String).join(' ');
      g.__legadoHostCall(-1, ['info', prefix + text]);
    };
  };
  g.console = {
    log: log(''), info: log(''), debug: log(''),
    warn: log('[warn] '), error: log('[error] ')
  };
  g.print = log('');

  // ---- 书源常用的兼容扩展 --------------------------------------------
  // btoa / atob：Legado 的 Rhino 环境提供，QuickJS 没有（它不是浏览器）。
  if (typeof g.btoa !== 'function') {
    var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    g.btoa = function (input) {
      var s = String(input);
      var out = '';
      for (var i = 0; i < s.length; i += 3) {
        var c1 = s.charCodeAt(i);
        var c2 = i + 1 < s.length ? s.charCodeAt(i + 1) : NaN;
        var c3 = i + 2 < s.length ? s.charCodeAt(i + 2) : NaN;
        out += B64.charAt(c1 >> 2);
        out += B64.charAt(((c1 & 3) << 4) | ((c2 || 0) >> 4));
        out += isNaN(c2) ? '=' : B64.charAt(((c2 & 15) << 2) | ((c3 || 0) >> 6));
        out += isNaN(c3) ? '=' : B64.charAt(c3 & 63);
      }
      return out;
    };
    g.atob = function (input) {
      var s = String(input).replace(/[^A-Za-z0-9+/=]/g, '');
      var out = '';
      for (var i = 0; i < s.length; i += 4) {
        var pad2 = s.charAt(i + 2) === '=';
        var pad3 = s.charAt(i + 3) === '=';
        var n = (B64.indexOf(s.charAt(i)) << 18) |
                (B64.indexOf(s.charAt(i + 1)) << 12) |
                ((pad2 ? 0 : B64.indexOf(s.charAt(i + 2))) << 6) |
                (pad3 ? 0 : B64.indexOf(s.charAt(i + 3)));
        out += String.fromCharCode((n >> 16) & 255);
        if (!pad2) out += String.fromCharCode((n >> 8) & 255);
        if (!pad3) out += String.fromCharCode(n & 255);
      }
      return out;
    };
  }

  // Legado(Rhino) 的 replaceAll 对**所有**匹配生效；QuickJS 原生实现
  // 遇到没有 /g 的正则会抛错（ES 规范如此），书源里却常这么写。
  if (!String.prototype.__legadoReplaceAll) {
    var nativeReplaceAll = String.prototype.replaceAll;
    Object.defineProperty(String.prototype, 'replaceAll', {
      configurable: true,
      writable: true,
      value: function (search, replacement) {
        if (search instanceof RegExp && !search.global) {
          return this.replace(new RegExp(search.source, search.flags + 'g'), replacement);
        }
        return nativeReplaceAll.call(this, search, replacement);
      }
    });
    Object.defineProperty(String.prototype, '__legadoReplaceAll', {
      configurable: true, value: true
    });
  }

  if (typeof g.__legadoRun !== 'function') {
    // 直接 eval：var / let / const 都留在本函数的作用域里，不会挂到 globalThis
    // 上（全局 var 是非配置属性，delete 不掉，会让下一段脚本看到上一段的变量）。
    g.__legadoRun = function (code) {
      return eval(code);
    };
    // 顶层 return 兼容：开头不换行，脚本第 1 行仍然是 eval 代码的第 1 行，
    // 报错行号不用再做偏移。
    g.__legadoRunFn = function (code) {
      return eval('(function(){' + code + '\n}).call(this)');
    };
    // JSON 表达不了 NaN / Infinity（会变成 null），单独打个标记让 Dart 侧还原。
    g.__legadoResult = function (value) {
      if (typeof value === 'number' && !isFinite(value)) {
        return { __legadoNum: String(value) };
      }
      return value;
    };
  }

  var spec = g.__legadoSpec || {};
  for (var name in spec) {
    g[name] = g.__legadoDecode(spec[name]);
  }
})();
''';
}
