import 'dart:math' as math;

import 'ast.dart';
import 'builtins.dart';
import 'js_exception.dart';
import 'scope.dart';
import 'values.dart';

/// 用 Dart 异常实现的 JS 控制流。
class ReturnSignal implements Exception {
  ReturnSignal(this.value);

  final Object? value;
}

class BreakSignal implements Exception {
  BreakSignal(this.label);

  final String? label;
}

class ContinueSignal implements Exception {
  ContinueSignal(this.label);

  final String? label;
}

/// `throw` 抛出的 JS 值。
class JsThrow implements Exception {
  JsThrow(this.value, this.line, this.column);

  final Object? value;
  final int line;
  final int column;
}

/// 用户脚本函数（声明、表达式、箭头函数）。
class UserFunction extends JsCallable {
  UserFunction({
    required this.name,
    required this.params,
    required this.body,
    required this.closure,
    required this.interpreter,
    this.isArrow = false,
    this.expressionBody,
    this.capturedThis,
  });

  @override
  final String name;
  final List<Param> params;

  /// 语句体；箭头函数表达式体时为 null。
  final List<Stmt>? body;
  final Expr? expressionBody;
  final Scope closure;
  final Interpreter interpreter;
  final bool isArrow;
  final Object? capturedThis;

  /// 脚本给函数挂的属性（`f.foo = 1`）。
  final Map<String, Object?> props = <String, Object?>{};

  @override
  Object? call(List<Object?> args, Object? thisArg) {
    // 函数体是异步执行的（宿主函数可能返回 Future），所以这里返回的是
    // Future；解释器统一走 [JsCallable.callAsync] 解包，脚本侧看不到 Future。
    return interpreter.invokeUserFunction(this, args, isArrow ? capturedThis : thisArg);
  }

  @override
  Object? construct(List<Object?> args) {
    return constructAsync(args);
  }

  @override
  Future<Object?> constructAsync(List<Object?> args) async {
    final thisObj = <String, Object?>{};
    final result = await interpreter.invokeUserFunction(this, args, thisObj);
    return (result is Map || result is List || result is JsHostObject) ? result : thisObj;
  }
}

/// 纯 Dart 的 JS 子集解释器。
class Interpreter {
  Interpreter({this.onLog, String script = ''}) : _script = script;

  final void Function(String level, String msg)? onLog;
  final String _script;

  late final Scope global;
  late final Map<String, NativeFunction> _stringMethods = createStringMethods(this);
  late final Map<String, NativeFunction> _arrayMethods = createArrayMethods(this);

  Object? _thisValue;
  int _depth = 0;
  static const int _maxDepth = 220;

  List<String>? _lines;


  // ------------------------------------------------------------------ setup

  Future<Object?> run(Program program, Map<String, Object?> bindings) async {
    global = Scope(null, functionScope: true);
    _scope = global;
    installGlobals(this, global);
    for (final entry in bindings.entries) {
      global.define(entry.key, entry.value);
    }
    _hoist(program.body, global);
    Object? completion;
    try {
      for (final stmt in program.body) {
        // JS eval 的返回值是最后一条语句的完成值，书源脚本几乎全靠这个。
        final v = await _exec(stmt);
        if (v != null) completion = v;
      }
    } on ReturnSignal catch (r) {
      return r.value;
    } on JsThrow catch (t) {
      throw JsException(
        '未捕获的异常: ${jsToString(t.value)}',
        line: t.line,
        column: t.column,
        sourceLine: sourceLine(t.line),
        script: _script,
      );
    }
    return completion;
  }

  String? sourceLine(int line) {
    if (_lines == null) {
      _lines = _script.split('\n');
      if (_lines!.isNotEmpty && _lines!.last.isEmpty) _lines!.removeLast();
    }
    if (line >= 1 && line <= _lines!.length) {
      final l = _lines![line - 1];
      return l.endsWith('\r') ? l.substring(0, l.length - 1) : l;
    }
    return null;
  }

  Never fail(String message, [Node? node]) {
    throw JsException(
      message,
      line: node?.line,
      column: node?.column,
      sourceLine: node == null ? null : sourceLine(node.line),
      script: _script,
    );
  }

  void log(String message) {
    final l = onLog;
    if (l != null) {
      l('info', message);
    }
  }

  // ------------------------------------------------------------------ hoist

  void _hoist(List<Stmt> stmts, Scope scope) {
    for (final s in stmts) {
      switch (s) {
        case final VarDeclStmt d:
          if (d.kind == 'var') {
            final target = scope.varScope;
            for (final decl in d.decls) {
              if (!target.contains(decl.name)) target.define(decl.name, null);
            }
          }
        case final FuncDecl f:
          scope.define(
            f.name,
            UserFunction(
              name: f.name,
              params: f.params,
              body: f.body,
              closure: scope,
              interpreter: this,
            ),
          );
        case final BlockStmt b:
          _hoist(b.body, scope);
        case final IfStmt i:
          _hoist([i.consequent], scope);
          if (i.alternate != null) _hoist([i.alternate!], scope);
        case final ForStmt f:
          final init = f.init;
          if (init is VarDeclStmt) _hoist([init], scope);
          _hoist([f.body], scope);
        case final ForInStmt f:
          if (f.declKind == 'var') {
            final left = f.left;
            if (left is Ident) {
              final target = scope.varScope;
              if (!target.contains(left.name)) target.define(left.name, null);
            }
          }
          _hoist([f.body], scope);
        case final WhileStmt w:
          _hoist([w.body], scope);
        case final DoWhileStmt w:
          _hoist([w.body], scope);
        case final TryStmt t:
          _hoist(t.block.body, scope);
          if (t.catchBlock != null) _hoist(t.catchBlock!.body, scope);
          if (t.finallyBlock != null) _hoist(t.finallyBlock!.body, scope);
        case final SwitchStmt sw:
          for (final c in sw.cases) {
            _hoist(c.body, scope);
          }
        case final LabeledStmt l:
          _hoist([l.body], scope);
        default:
          break;
      }
    }
  }

  // -------------------------------------------------------------- statements

  /// 返回语句的「完成值」（JS Completion Value），用于 `eval` 取最后一条
  /// 表达式语句的结果；不支持的场景返回 null。
  Future<Object?> _exec(Stmt s) async {
    switch (s) {
      case final EmptyStmt _:
        return null;
      case final ExprStmt e:
        return _eval(e.expr);
      case final VarDeclStmt d:
        for (final decl in d.decls) {
          final value = decl.init == null ? null : await _eval(decl.init!);
          if (d.kind == 'var') {
            _scope.varScope.define(decl.name, value);
          } else {
            _scope.define(decl.name, value, isConst: d.kind == 'const');
          }
        }
        return null;
      case final FuncDecl _:
        // 提升阶段已处理
        return null;
      case final BlockStmt b:
        return _execBlock(b, _scope);
      case final ReturnStmt r:
        final v = r.value == null ? null : await _eval(r.value!);
        throw ReturnSignal(v);
      case final IfStmt i:
        if (jsToBoolean(await _eval(i.test))) {
          return _exec(i.consequent);
        } else if (i.alternate != null) {
          return _exec(i.alternate!);
        }
        return null;
      case final ForStmt f:
        await _execFor(f, null);
        return null;
      case final ForInStmt f:
        await _execForIn(f, null);
        return null;
      case final WhileStmt w:
        await _execWhile(w, null);
        return null;
      case final DoWhileStmt w:
        await _execDoWhile(w, null);
        return null;
      case final SwitchStmt sw:
        await _execSwitch(sw);
        return null;
      case final TryStmt t:
        return _execTry(t);
      case final ThrowStmt t:
        throw JsThrow(await _eval(t.value), t.line, t.column);
      case final BreakStmt b:
        throw BreakSignal(b.label);
      case final ContinueStmt c:
        throw ContinueSignal(c.label);
      case final LabeledStmt l:
        await _execLabeled(l);
        return null;
    }
    return null;
  }

  Scope _scope = Scope(null, functionScope: true);

  Future<Object?> _execBlock(BlockStmt b, Scope parent) async {
    final scope = Scope(parent);
    final saved = _scope;
    _scope = scope;
    Object? completion;
    try {
      _hoist(b.body, scope);
      for (final s in b.body) {
        final v = await _exec(s);
        if (v != null) completion = v;
      }
    } finally {
      _scope = saved;
    }
    return completion;
  }

  Future<void> _execFor(ForStmt f, String? label) async {
    final parent = _scope;
    final loopScope = Scope(parent);
    final saved = _scope;

    final letNames = <String>[];
    if (f.init is VarDeclStmt) {
      final decl = f.init as VarDeclStmt;
      if (decl.kind != 'var') {
        for (final d in decl.decls) {
          letNames.add(d.name);
        }
      }
    }

    _scope = loopScope;
    try {
      final init = f.init;
      if (init is VarDeclStmt) _hoist(<Stmt>[init], loopScope);
      if (init != null) await _exec(init as Stmt);

      var current = loopScope;
      var iterations = 0;
      while (true) {
        if (++iterations > 10000000) fail('for 循环次数过多（可能是死循环）', f);
        _scope = current;
        if (f.test != null && !jsToBoolean(await _eval(f.test!))) break;
        try {
          await _exec(f.body);
        } on BreakSignal catch (b) {
          if (b.label == null || b.label == label) break;
          rethrow;
        } on ContinueSignal catch (c) {
          if (c.label != null && c.label != label) rethrow;
        }
        if (letNames.isNotEmpty) {
          final next = Scope(parent);
          for (final name in letNames) {
            next.define(name, current.lookup(name));
          }
          current = next;
        }
        _scope = current;
        if (f.update != null) await _eval(f.update!);
      }
    } finally {
      _scope = saved;
    }
  }

  Future<void> _execForIn(ForInStmt f, String? label) async {
    final parent = _scope;
    final right = await _eval(f.right);
    final List<Object?> values = <Object?>[];
    final Iterable<Object?> items;
    if (f.isOf) {
      if (right is List) {
        items = right.toList();
      } else if (right is String) {
        items = right.split('');
      } else if (right is Map) {
        items = right.values.toList();
      } else if (right is JsHostObject) {
        items = right.ownKeys();
      } else if (right == null) {
        fail('for...of 的右边不是可迭代对象', f);
      } else {
        fail('for...of 的右边不是可迭代对象: ${describeJsValue(right)}', f);
      }
    } else {
      if (right is List) {
        items = List<Object?>.generate(right.length, (i) => i);
      } else if (right is String) {
        items = List<Object?>.generate(right.length, (i) => i);
      } else if (right is Map) {
        items = right.keys.toList();
      } else if (right is JsHostObject) {
        items = right.ownKeys();
      } else if (right == null) {
        items = const <Object?>[];
      } else {
        items = const <Object?>[];
      }
    }
    values.addAll(items);

    final saved = _scope;
    try {
      for (final v in values) {
        if (f.declKind == null) {
          _scope = parent;
          await _assignTo(f.left, v, f);
        } else if (f.declKind == 'var') {
          _scope = parent;
          await _assignTo(f.left, v, f);
        } else {
          final iterScope = Scope(parent);
          _scope = iterScope;
          final left = f.left;
          if (left is Ident) {
            iterScope.define(left.name, v, isConst: f.declKind == 'const');
          } else {
            fail('for...in/of 左边只能是标识符', f);
          }
        }
        try {
          await _exec(f.body);
        } on BreakSignal catch (b) {
          if (b.label == null || b.label == label) break;
          rethrow;
        } on ContinueSignal catch (c) {
          if (c.label != null && c.label != label) rethrow;
        }
      }
    } finally {
      _scope = saved;
    }
  }

  Future<void> _execWhile(WhileStmt w, String? label) async {
    var iterations = 0;
    while (jsToBoolean(await _eval(w.test))) {
      if (++iterations > 10000000) fail('while 循环次数过多（可能是死循环）', w);
      try {
        await _exec(w.body);
      } on BreakSignal catch (b) {
        if (b.label == null || b.label == label) break;
        rethrow;
      } on ContinueSignal catch (c) {
        if (c.label != null && c.label != label) rethrow;
      }
    }
  }

  Future<void> _execDoWhile(DoWhileStmt w, String? label) async {
    var iterations = 0;
    do {
      if (++iterations > 10000000) fail('do...while 循环次数过多（可能是死循环）', w);
      try {
        await _exec(w.body);
      } on BreakSignal catch (b) {
        if (b.label == null || b.label == label) break;
        rethrow;
      } on ContinueSignal catch (c) {
        if (c.label != null && c.label != label) rethrow;
        continue;
      }
    } while (jsToBoolean(await _eval(w.test)));
  }

  Future<void> _execSwitch(SwitchStmt sw) async {
    final disc = await _eval(sw.discriminant);
    final scope = Scope(_scope);
    final saved = _scope;
    _scope = scope;
    try {
      for (final c in sw.cases) {
        _hoist(c.body, scope);
      }
      var matched = false;
      var defaultIndex = -1;
      for (var i = 0; i < sw.cases.length; i++) {
        final c = sw.cases[i];
        if (c.test == null) {
          defaultIndex = i;
        } else if (!matched && jsStrictEquals(disc, await _eval(c.test!))) {
          matched = true;
          if (await _runCase(c)) return;
          for (var j = i + 1; j < sw.cases.length; j++) {
            if (await _runCase(sw.cases[j])) return;
          }
          return;
        }
      }
      if (!matched && defaultIndex >= 0) {
        for (var j = defaultIndex; j < sw.cases.length; j++) {
          if (await _runCase(sw.cases[j])) return;
        }
      }
    } finally {
      _scope = saved;
    }
  }

  /// 返回 true 表示遇到 break。
  Future<bool> _runCase(SwitchCase c) async {
    try {
      for (final s in c.body) {
        await _exec(s);
      }
    } on BreakSignal catch (b) {
      if (b.label == null) return true;
      rethrow;
    }
    return false;
  }

  Future<Object?> _execTry(TryStmt t) async {
    Object? completion;
    try {
      completion = await _execBlock(t.block, _scope);
    } on JsThrow catch (e) {
      final cb = t.catchBlock;
      if (cb == null) rethrow;
      final scope = Scope(_scope);
      if (t.catchParam != null) scope.define(t.catchParam!, e.value);
      completion = await _execBlock(cb, scope);
    } on JsException catch (e) {
      // 引擎自身抛出的运行时错误（`JSON.parse` 失败、属性不存在、除零……）
      // 也必须能被 JS 的 `try/catch` 捕获。
      //
      // 原版 Rhino 里这些是标准的 JS 异常，书源里 `try { ... } catch(e) { }`
      // 是常见写法——不接住的话，一条规则里的解析失败会直接把整本书的
      // 目录/正文流程打断，而不是退回书源预设的降级分支。
      final cb = t.catchBlock;
      if (cb == null) rethrow;
      final scope = Scope(_scope);
      if (t.catchParam != null) {
        scope.define(t.catchParam!, _errorToJsValue(e));
      }
      completion = await _execBlock(cb, scope);
    } finally {
      final fb = t.finallyBlock;
      if (fb != null) {
        await _execBlock(fb, _scope);
      }
    }
    return completion;
  }

  /// 把引擎异常转成 JS 里能读的 Error 对象。
  ///
  /// 书源里常见的用法是 `catch(e) { e.message }` 或 `String(e)`，
  /// 所以要提供 `message` / `name` 两个字段。
  Object _errorToJsValue(JsException e) {
    return JsHostObject(
      label: 'Error',
      props: {'name': 'Error', 'message': e.message},
      methods: const {},
    );
  }

  Future<void> _execLabeled(LabeledStmt l) async {
    final body = l.body;
    if (body is ForStmt) {
      await _execFor(body, l.label);
      return;
    }
    if (body is ForInStmt) {
      await _execForIn(body, l.label);
      return;
    }
    if (body is WhileStmt) {
      await _execWhile(body, l.label);
      return;
    }
    if (body is DoWhileStmt) {
      await _execDoWhile(body, l.label);
      return;
    }
    try {
      await _exec(body);
    } on BreakSignal catch (b) {
      if (b.label != null && b.label != l.label) rethrow;
    } on ContinueSignal catch (c) {
      if (c.label != null && c.label != l.label) rethrow;
    }
  }

  // ------------------------------------------------------------- expressions

  Future<Object?> _eval(Expr e) async {
    switch (e) {
      case final NumLit n:
        return n.value;
      case final StrLit s:
        return s.value;
      case final BoolLit b:
        return b.value;
      case final NullLit _:
        return null;
      case final TemplateLit t:
        final buf = StringBuffer();
        for (final p in t.parts) {
          if (p is String) {
            buf.write(p);
          } else if (p is Expr) {
            buf.write(jsToString(await _eval(p)));
          }
        }
        return buf.toString();
      case final RegexLit r:
        return JsRegExp(r.pattern, r.flags);
      case final ArrayLit a:
        return _evalArray(a);
      case final ObjectLit o:
        return _evalObject(o);
      case final Ident id:
        return _lookup(id);
      case final ThisExpr _:
        return _thisValue;
      case final MemberExpr m:
        return _evalMember(m);
      case final CallExpr c:
        return _evalCall(c);
      case final NewExpr n:
        return _evalNew(n);
      case final UnaryExpr u:
        return _evalUnary(u);
      case final UpdateExpr u:
        return _evalUpdate(u);
      case final BinaryExpr b:
        return _evalBinary(b);
      case final LogicalExpr l:
        return _evalLogical(l);
      case final AssignExpr a:
        return _evalAssign(a);
      case final ConditionalExpr c:
        return jsToBoolean(await _eval(c.test))
            ? await _eval(c.consequent)
            : await _eval(c.alternate);
      case final SequenceExpr s:
        Object? last;
        for (final x in s.exprs) {
          last = await _eval(x);
        }
        return last;
      case final FuncExpr f:
        return UserFunction(
          name: f.name ?? '',
          params: f.params,
          body: f.body,
          closure: _scope,
          interpreter: this,
        );
      case final ArrowFn f:
        return UserFunction(
          name: '',
          params: f.params,
          body: f.isExpressionBody ? null : f.body as List<Stmt>,
          expressionBody: f.isExpressionBody ? f.body as Expr : null,
          closure: _scope,
          interpreter: this,
          isArrow: true,
          capturedThis: _thisValue,
        );
      case final SpreadExpr s:
        fail('展开运算符不能单独求值', s);
    }
    return null;
  }

  Object? _lookup(Ident id) {
    if (!_scope.has(id.name)) {
      fail('ReferenceError: "${id.name}" 未定义', id);
    }
    return _scope.lookup(id.name);
  }

  Future<Object?> _evalArray(ArrayLit a) async {
    final list = <Object?>[];
    for (final el in a.elements) {
      if (el == null) {
        list.add(null);
      } else if (el is SpreadExpr) {
        final v = await _eval(el.argument);
        if (v is List) {
          list.addAll(v);
        } else if (v is String) {
          list.addAll(v.split(''));
        } else if (v is Map) {
          fail('展开 Map 到数组没有意义', el);
        } else if (v != null) {
          fail('${describeJsValue(v)} 不是可迭代对象', el);
        }
      } else {
        list.add(await _eval(el));
      }
    }
    return list;
  }

  Future<Object?> _evalObject(ObjectLit o) async {
    final map = <String, Object?>{};
    for (final p in o.props) {
      if (p.value is SpreadExpr) {
        final v = await _eval((p.value as SpreadExpr).argument);
        if (v is Map) {
          v.forEach((k, val) => map[jsToString(k)] = val);
        } else if (v is JsHostObject) {
          for (final k in v.ownKeys()) {
            map[k] = v.getProperty(k);
          }
        } else if (v != null) {
          fail('只能展开对象，实际是 ${describeJsValue(v)}', p);
        }
        continue;
      }
      final key =
          p.computedKey != null ? jsToString(await _eval(p.computedKey!)) : p.key!;
      map[key] = await _eval(p.value);
    }
    return map;
  }

  Future<Object?> _evalMember(MemberExpr m) async {
    final obj = await _eval(m.object);
    if (obj == null && m.optional) return null;
    final key = m.computed ? await _eval(m.property as Expr) : m.property;
    return getProperty(obj, key, optional: m.optional, node: m);
  }

  Future<Object?> _evalCall(CallExpr c) async {
    Object? thisArg;
    Object? fn;
    if (c.callee is MemberExpr) {
      final m = c.callee as MemberExpr;
      final obj = await _eval(m.object);
      if (obj == null && m.optional) return null;
      thisArg = obj;
      final key = m.computed ? await _eval(m.property as Expr) : m.property;
      fn = getProperty(obj, key, optional: m.optional, node: m);
    } else {
      fn = await _eval(c.callee);
    }
    if (fn == null && c.optional) return null;
    final args = await _evalArgs(c.args);
    return callFunction(fn, args, thisArg: thisArg, node: c);
  }

  Future<Object?> _evalNew(NewExpr n) async {
    final ctor = await _eval(n.callee);
    final args = await _evalArgs(n.args);
    if (ctor is JsCallable) {
      _depth++;
      try {
        if (_depth > _maxDepth) fail('调用嵌套过深（可能是无限递归）', n);
        return await ctor.constructAsync(args);
      } on JsException catch (e) {
        if (e.line == null) {
          throw e.withLocation(
              line: n.line, column: n.column, sourceLine: sourceLine(n.line));
        }
        rethrow;
      } finally {
        _depth--;
      }
    }
    if (ctor is Function) {
      return callFunction(ctor, args, node: n);
    }
    fail('${describeJsValue(ctor)} 不是构造函数', n);
  }

  Future<List<Object?>> _evalArgs(List<Expr> args) async {
    final out = <Object?>[];
    for (final a in args) {
      if (a is SpreadExpr) {
        final v = await _eval(a.argument);
        if (v is List) {
          out.addAll(v);
        } else if (v is String) {
          out.addAll(v.split(''));
        } else if (v is Map) {
          fail('展开 Map 到参数列表没有意义', a);
        } else if (v != null) {
          fail('${describeJsValue(v)} 不能展开', a);
        }
      } else {
        out.add(await _eval(a));
      }
    }
    return out;
  }

  Future<Object?> _evalUnary(UnaryExpr u) async {
    switch (u.op) {
      case '!':
        return !jsToBoolean(await _eval(u.argument));
      case '-':
        return -jsToNumber(await _eval(u.argument));
      case '+':
        return jsToNumber(await _eval(u.argument));
      case '~':
        return ~_toInt32(await _eval(u.argument));
      case 'typeof':
        final arg = u.argument;
        if (arg is Ident && !_scope.has(arg.name)) return 'undefined';
        return jsTypeOf(await _eval(arg));
      case 'void':
        await _eval(u.argument);
        return null;
      case 'delete':
        return _delete(u.argument);
    }
    fail('不支持的运算符 ${u.op}', u);
  }

  Future<bool> _delete(Expr target) async {
    if (target is MemberExpr) {
      final obj = await _eval(target.object);
      final key = target.computed ? await _eval(target.property as Expr) : target.property;
      if (obj is Map) {
        obj.remove(jsToString(key));
        return true;
      }
      if (obj is List) {
        final i = _indexOf(key);
        if (i != null && i >= 0 && i < obj.length) obj[i] = null;
        return true;
      }
      if (obj is JsHostObject) {
        obj.props.remove(jsToString(key));
        obj.methods.remove(jsToString(key));
        return true;
      }
      return true;
    }
    if (target is Ident) {
      return true;
    }
    fail('delete 的目标必须是属性访问', target);
  }

  Future<Object?> _evalUpdate(UpdateExpr u) async {
    final ref = await _resolveRef(u.argument);
    final old = jsToNumber(ref.get());
    final next = u.op == '++' ? old + 1 : old - 1;
    ref.set(next);
    return u.prefix ? next : old;
  }

  Future<Object?> _evalLogical(LogicalExpr l) async {
    final left = await _eval(l.left);
    switch (l.op) {
      case '&&':
        return jsToBoolean(left) ? await _eval(l.right) : left;
      case '||':
        return jsToBoolean(left) ? left : await _eval(l.right);
      case '??':
        return left ?? await _eval(l.right);
    }
    fail('不支持的逻辑运算符 ${l.op}', l);
  }

  Future<Object?> _evalBinary(BinaryExpr b) async {
    final left = await _eval(b.left);
    final right = await _eval(b.right);
    switch (b.op) {
      case '+':
        final lp = jsToPrimitive(left);
        final rp = jsToPrimitive(right);
        if (lp is String || rp is String) {
          return jsToString(lp) + jsToString(rp);
        }
        return jsToNumber(lp) + jsToNumber(rp);
      case '-':
        return jsToNumber(left) - jsToNumber(right);
      case '*':
        return jsToNumber(left) * jsToNumber(right);
      case '/':
        return jsToNumber(left) / jsToNumber(right);
      case '%':
        return jsToNumber(left) % jsToNumber(right);
      case '**':
        return _pow(jsToNumber(left), jsToNumber(right));
      case '==':
        return jsLooseEquals(left, right);
      case '!=':
        return !jsLooseEquals(left, right);
      case '===':
        return jsStrictEquals(left, right);
      case '!==':
        return !jsStrictEquals(left, right);
      case '<':
      case '>':
      case '<=':
      case '>=':
        return _compare(b.op, left, right);
      case '&':
        return _toInt32(left) & _toInt32(right);
      case '|':
        return _toInt32(left) | _toInt32(right);
      case '^':
        return _toInt32(left) ^ _toInt32(right);
      case '<<':
        return _toInt32(left) << (_toInt32(right) & 31);
      case '>>':
        return _toInt32(left) >> (_toInt32(right) & 31);
      case '>>>':
        return (_toInt32(left) & 0xFFFFFFFF) >>> (_toInt32(right) & 31);
      case 'in':
        return _inOperator(left, right);
      case 'instanceof':
        return _instanceOf(left, right);
    }
    fail('不支持的运算符 ${b.op}', b);
  }

  bool _compare(String op, Object? left, Object? right) {
    final lp = jsToPrimitive(left);
    final rp = jsToPrimitive(right);
    if (lp is String && rp is String) {
      final c = lp.compareTo(rp);
      switch (op) {
        case '<':
          return c < 0;
        case '>':
          return c > 0;
        case '<=':
          return c <= 0;
        case '>=':
          return c >= 0;
      }
    }
    final l = jsToNumber(lp);
    final r = jsToNumber(rp);
    if (l.isNaN || r.isNaN) return false;
    switch (op) {
      case '<':
        return l < r;
      case '>':
        return l > r;
      case '<=':
        return l <= r;
      case '>=':
        return l >= r;
    }
    return false;
  }

  bool _inOperator(Object? key, Object? obj) {
    final k = jsToString(key);
    if (obj is Map) return obj.containsKey(k);
    if (obj is List) {
      final i = int.tryParse(k);
      return i != null && i >= 0 && i < obj.length;
    }
    if (obj is JsHostObject) return obj.hasProperty(k);
    if (obj == null) fail('Cannot use "in" on undefined');
    return false;
  }

  bool _instanceOf(Object? value, Object? ctor) {
    String? name;
    if (ctor is JsCallable) name = ctor.name;
    if (ctor is JsHostObject) name = ctor.name;
    switch (name) {
      case 'Array':
        return value is List;
      case 'Object':
        return value is Map || value is List || value is JsHostObject;
      case 'String':
        return value is String;
      case 'Number':
        return value is num;
      case 'Boolean':
        return value is bool;
      case 'Function':
        return value is JsCallable || value is Function;
      case 'RegExp':
        return value is JsRegExp;
      case 'Date':
        return value is JsDate;
      case 'Error':
        return false;
    }
    return false;
  }

  num _pow(num a, num b) => math.pow(a, b);

  Future<Object?> _evalAssign(AssignExpr a) async {
    if (a.target is Ident || a.target is MemberExpr) {
      final ref = await _resolveRef(a.target);
      if (a.op == '=') {
        final v = await _eval(a.value);
        ref.set(v);
        return v;
      }
      final cur = ref.get();
      final rhs = await _eval(a.value);
      final op = a.op.substring(0, a.op.length - 1);
      final v = _applyCompound(op, cur, rhs, a);
      ref.set(v);
      return v;
    }
    fail('赋值目标不合法', a);
  }

  Object? _applyCompound(String op, Object? cur, Object? rhs, Node node) {
    switch (op) {
      case '+':
        final lp = jsToPrimitive(cur);
        final rp = jsToPrimitive(rhs);
        if (lp is String || rp is String) return jsToString(lp) + jsToString(rp);
        return jsToNumber(lp) + jsToNumber(rp);
      case '-':
        return jsToNumber(cur) - jsToNumber(rhs);
      case '*':
        return jsToNumber(cur) * jsToNumber(rhs);
      case '/':
        return jsToNumber(cur) / jsToNumber(rhs);
      case '%':
        return jsToNumber(cur) % jsToNumber(rhs);
      case '**':
        return _pow(jsToNumber(cur), jsToNumber(rhs));
      case '&':
        return _toInt32(cur) & _toInt32(rhs);
      case '|':
        return _toInt32(cur) | _toInt32(rhs);
      case '^':
        return _toInt32(cur) ^ _toInt32(rhs);
      case '<<':
        return _toInt32(cur) << (_toInt32(rhs) & 31);
      case '>>':
        return _toInt32(cur) >> (_toInt32(rhs) & 31);
      case '>>>':
        return (_toInt32(cur) & 0xFFFFFFFF) >>> (_toInt32(rhs) & 31);
    }
    fail('不支持的复合赋值 $op=', node);
  }

  Future<void> _assignTo(Expr target, Object? value, Node node) async {
    final ref = await _resolveRef(target);
    ref.set(value);
  }

  Future<_Ref> _resolveRef(Expr target) async {
    if (target is Ident) {
      final name = target.name;
      return _Ref(
        () => _scope.has(name) ? _scope.lookup(name) : fail('ReferenceError: "$name" 未定义', target),
        (v) => _scope.assign(name, v),
        name,
        target,
      );
    }
    if (target is MemberExpr) {
      final obj = await _eval(target.object);
      final key = target.computed ? await _eval(target.property as Expr) : target.property;
      return _Ref(
        () => getProperty(obj, key, node: target),
        (v) => setProperty(obj, key, v, node: target),
        jsToString(key),
        target,
      );
    }
    fail('不是合法的赋值目标', target);
  }

  // ------------------------------------------------------------ 属性/调用 API

  Object? getProperty(Object? obj, Object? key, {bool optional = false, Node? node}) {
    if (obj == null) {
      if (optional) return null;
      fail("TypeError: 不能读取 ${describeJsValue(obj)} 的属性 '${jsToString(key)}'", node);
    }
    final ks = jsToString(key);

    if (obj is JsHostObject) {
      final v = obj.getProperty(ks);
      if (v != null || obj.hasProperty(ks)) return v;
      return null;
    }

    if (obj is List) {
      if (obj is JsArray && obj.props.containsKey(ks)) return obj.props[ks];
      if (ks == 'length') return obj.length;
      final idx = _indexOf(key);
      if (idx != null) {
        if (idx < 0 || idx >= obj.length) return null;
        return obj[idx];
      }
      final m = _arrayMethods[ks];
      if (m != null) return m;
      return null;
    }

    if (obj is String) {
      if (ks == 'length') return obj.length;
      final idx = _indexOf(key);
      if (idx != null) {
        if (idx < 0 || idx >= obj.length) return null;
        return obj[idx];
      }
      final m = _stringMethods[ks];
      if (m != null) return m;
      return null;
    }

    if (obj is Map) {
      if (obj.containsKey(ks)) return obj[ks];
      switch (ks) {
        case 'hasOwnProperty':
          return NativeFunction('hasOwnProperty', (args, _) {
            final k = args.isEmpty ? '' : jsToString(args[0]);
            return obj.containsKey(k);
          });
        case 'toString':
          return NativeFunction('toString', (args, _) => '[object Object]');
        case 'valueOf':
          return NativeFunction('valueOf', (args, _) => obj);
      }
      return null;
    }

    if (obj is JsRegExp) {
      switch (ks) {
        case 'source':
          return obj.source;
        case 'flags':
          return obj.flags;
        case 'global':
          return obj.global;
        case 'ignoreCase':
          return obj.ignoreCase;
        case 'multiline':
          return obj.multiline;
        case 'lastIndex':
          return obj.lastIndex;
        case 'test':
          return NativeFunction('test', (args, _) => regexTest(this, obj, args));
        case 'exec':
          return NativeFunction('exec', (args, _) => regexExec(this, obj, args));
        case 'toString':
          return NativeFunction('toString', (args, _) => obj.toString());
      }
      return null;
    }

    if (obj is JsDate) {
      switch (ks) {
        case 'getFullYear':
          return NativeFunction(ks, (a, _) => obj.getFullYear());
        case 'getMonth':
          return NativeFunction(ks, (a, _) => obj.getMonth());
        case 'getDate':
          return NativeFunction(ks, (a, _) => obj.getDate());
        case 'getDay':
          return NativeFunction(ks, (a, _) => obj.getDay());
        case 'getHours':
          return NativeFunction(ks, (a, _) => obj.getHours());
        case 'getMinutes':
          return NativeFunction(ks, (a, _) => obj.getMinutes());
        case 'getSeconds':
          return NativeFunction(ks, (a, _) => obj.getSeconds());
        case 'getMilliseconds':
          return NativeFunction(ks, (a, _) => obj.getMilliseconds());
        case 'getUTCFullYear':
          return NativeFunction(ks, (a, _) => obj.getUTCFullYear());
        case 'getUTCMonth':
          return NativeFunction(ks, (a, _) => obj.getUTCMonth());
        case 'getUTCDate':
          return NativeFunction(ks, (a, _) => obj.getUTCDate());
        case 'getUTCHours':
          return NativeFunction(ks, (a, _) => obj.getUTCHours());
        case 'getTime':
        case 'valueOf':
          return NativeFunction(ks, (a, _) => obj.getTime());
        case 'toISOString':
          return NativeFunction(ks, (a, _) => obj.toISOString());
        case 'toString':
          return NativeFunction(ks, (a, _) => obj.toString());
        case 'toJSON':
          return NativeFunction(ks, (a, _) => obj.toISOString());
      }
      return null;
    }

    if (obj is num) {
      switch (ks) {
        case 'toFixed':
          return NativeFunction('toFixed', (args, _) {
            final digits = args.isEmpty ? 0 : jsToNumber(args[0]).toInt();
            return obj.toDouble().toStringAsFixed(digits.clamp(0, 100));
          });
        case 'toString':
          return NativeFunction('toString', (args, _) {
            if (args.isNotEmpty && args[0] != null) {
              final radix = jsToNumber(args[0]).toInt();
              if (radix >= 2 && radix <= 36) {
                final n = obj.truncate();
                return n.toRadixString(radix);
              }
            }
            return numToJsString(obj);
          });
        case 'valueOf':
          return NativeFunction('valueOf', (args, _) => obj);
        case 'toPrecision':
          return NativeFunction('toPrecision', (args, _) {
            if (args.isEmpty) return numToJsString(obj);
            final p = jsToNumber(args[0]).toInt();
            return obj.toDouble().toStringAsPrecision(p.clamp(1, 21));
          });
      }
      return null;
    }

    if (obj is bool) {
      switch (ks) {
        case 'toString':
          return NativeFunction('toString', (args, _) => obj ? 'true' : 'false');
        case 'valueOf':
          return NativeFunction('valueOf', (args, _) => obj);
      }
      return null;
    }

    if (obj is UserFunction && obj.props.containsKey(ks)) {
      return obj.props[ks];
    }

    if (obj is JsCallable) {
      switch (ks) {
        case 'name':
          return obj.name;
        case 'length':
          return 0;
        case 'call':
          return NativeFunction('call', (args, thisArg) {
            final fn = obj;
            final target = args.isEmpty ? null : args[0];
            final rest = args.length > 1 ? args.sublist(1) : const <Object?>[];
            return callFunction(fn, rest, thisArg: target, node: node);
          });
        case 'apply':
          return NativeFunction('apply', (args, thisArg) {
            final target = args.isEmpty ? null : args[0];
            final list = args.length > 1 && args[1] is List ? args[1] as List : const <Object?>[];
            return callFunction(obj, list, thisArg: target, node: node);
          });
        case 'bind':
          return NativeFunction('bind', (args, thisArg) {
            final boundThis = args.isEmpty ? null : args[0];
            final prefix = args.length > 1 ? args.sublist(1) : const <Object?>[];
            return NativeFunction(obj.name, (callArgs, _) {
              return callFunction(obj, [...prefix, ...callArgs], thisArg: boundThis, node: node);
            });
          });
      }
      return null;
    }

    // 兜底：JS 原生对象上读任何属性都返回 undefined，但明确报错更利于调试。
    return null;
  }

  void setProperty(Object? obj, Object? key, Object? value, {Node? node}) {
    if (obj == null) {
      fail('TypeError: 不能给 ${describeJsValue(obj)} 设置属性', node);
    }
    final ks = jsToString(key);
    if (obj is Map) {
      obj[ks] = value;
      return;
    }
    if (obj is List) {
      if (ks == 'length') {
        final n = jsToNumber(value).toInt();
        if (n < 0) fail('RangeError: 数组长度不能为负', node);
        if (n < obj.length) {
          obj.removeRange(n, obj.length);
        } else {
          while (obj.length < n) {
            obj.add(null);
          }
        }
        return;
      }
      final idx = _indexOf(key);
      if (idx != null) {
        if (idx < 0) fail('RangeError: 数组下标不能为负', node);
        while (obj.length <= idx) {
          obj.add(null);
        }
        obj[idx] = value;
        return;
      }
      fail("不能给数组设置属性 '$ks'", node);
    }
    if (obj is JsHostObject) {
      obj.setProperty(ks, value);
      return;
    }
    if (obj is JsRegExp) {
      if (ks == 'lastIndex') {
        obj.lastIndex = jsToNumber(value).toInt();
        return;
      }
      fail("不能给正则设置属性 '$ks'", node);
    }
    if (obj is UserFunction) {
      obj.props[ks] = value;
      return;
    }
    if (obj is JsArray) {
      obj.props[ks] = value;
      return;
    }
    fail("不能给 ${describeJsValue(obj)} 设置属性 '$ks'", node);
  }

  int? _indexOf(Object? key) {
    if (key is int) return key;
    if (key is num) {
      if (key == key.truncateToDouble()) return key.toInt();
      return null;
    }
    if (key is String) {
      final i = int.tryParse(key);
      if (i != null) return i;
    }
    return null;
  }

  /// 调用函数（脚本函数 / 宿主函数 / 原生函数）。
  ///
  /// 宿主方法可能返回 `Future`（`java.ajax` 要发网络请求），
  /// 这里统一 await 掉，脚本侧拿到的始终是最终结果，而不是 Future 对象。
  Future<Object?> callFunction(
    Object? fn,
    List<Object?> args, {
    Object? thisArg,
    Node? node,
  }) async {
    if (fn == null) {
      fail('TypeError: ${describeJsValue(fn)} 不是函数', node);
    }
    if (fn is JsCallable) {
      _depth++;
      try {
        if (_depth > _maxDepth) fail('调用嵌套过深（可能是无限递归）', node);
        final savedThis = _thisValue;
        _thisValue = thisArg;
        try {
          return await fn.callAsync(args, thisArg);
        } finally {
          _thisValue = savedThis;
        }
      } on JsException catch (e) {
        if (e.line == null && node != null) {
          throw e.withLocation(
            line: node.line,
            column: node.column,
            sourceLine: sourceLine(node.line),
          );
        }
        rethrow;
      } on ReturnSignal {
        rethrow;
      } on BreakSignal {
        rethrow;
      } on ContinueSignal {
        rethrow;
      } catch (e) {
        // 宿主函数抛出的普通 Dart 异常，对齐原版 Rhino：JS 的 try/catch
        // 能把它抓住（比如 `java.ajax` 网络失败）。只有栈溢出/内存耗尽
        // 这类致命错误保持原样往上抛，交给引擎最外层处理。
        if (e is StackOverflowError || e is OutOfMemoryError) rethrow;
        throw JsException(
          '调用出错: $e',
          line: node?.line,
          column: node?.column,
          sourceLine: node == null ? null : sourceLine(node.line),
          script: _script,
        );
      } finally {
        _depth--;
      }
    }
    if (fn is Function) {
      return await _callDartFunction(fn, args, node);
    }
    fail('TypeError: ${describeJsValue(fn)} 不是函数', node);
  }

  Future<Object?> _callDartFunction(Function fn, List<Object?> args, Node? node) async {
    try {
      Object? r;
      if (fn is Object? Function(List<Object?>)) {
        r = fn(args);
      } else if (fn is Object? Function()) {
        r = fn();
      } else {
        r = Function.apply(fn, args);
      }
      return r is Future ? await r : r;
    } catch (e, st) {
      if (e is JsException) rethrow;
      fail('宿主函数执行失败: $e\n$st', node);
    }
  }

  Future<Object?> invokeUserFunction(
    UserFunction fn,
    List<Object?> args,
    Object? thisArg,
  ) async {
    final scope = Scope(fn.closure, functionScope: true);
    final savedScope = _scope;
    final savedThis = _thisValue;
    _scope = scope;
    _thisValue = thisArg;
    _depth++;
    try {
      if (_depth > _maxDepth) fail('调用嵌套过深（可能是无限递归）');
      var i = 0;
      for (final p in fn.params) {
        if (p.rest) {
          scope.define(p.name, args.length > i ? args.sublist(i) : <Object?>[]);
          i = args.length;
          continue;
        }
        Object? v;
        if (i < args.length) {
          v = args[i];
        } else if (p.defaultValue != null) {
          v = await _eval(p.defaultValue!);
        } else {
          v = null;
        }
        scope.define(p.name, v);
        i++;
      }
      final argsObj = <String, Object?>{
        for (var j = 0; j < args.length; j++) '$j': args[j],
      };
      argsObj['length'] = args.length;
      scope.define('arguments', argsObj);

      _hoist(fn.body ?? const <Stmt>[], scope);

      final exprBody = fn.expressionBody;
      if (exprBody != null) {
        return await _eval(exprBody);
      }
      for (final s in fn.body!) {
        await _exec(s);
      }
      return null;
    } on ReturnSignal catch (r) {
      return r.value;
    } finally {
      _depth--;
      _scope = savedScope;
      _thisValue = savedThis;
    }
  }
}

class _Ref {
  _Ref(this.get, this.set, this.name, this.node);

  final Object? Function() get;
  final void Function(Object?) set;
  final String name;
  final Node node;
}

int _toInt32(Object? v) {
  final n = jsToNumber(v);
  if (n.isNaN || n.isInfinite) return 0;
  final i = n.truncate();
  final m = i % 4294967296;
  return m >= 2147483648 ? m - 4294967296 : m;
}
