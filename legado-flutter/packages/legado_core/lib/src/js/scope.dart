import 'js_exception.dart';

/// 作用域链。
///
/// - 顶层与函数体是「函数作用域」，`var` 提升到这里；
/// - 每个块（if/for/while/try/裸块）新建一层，承载 `let/const`。
/// TDZ 没有实现（读未赋值的 `let` 得到 null 而不是报错），书源脚本不受影响。
class Scope {
  Scope(this.parent, {this.functionScope = false});

  final Scope? parent;
  final bool functionScope;
  final Map<String, Object?> _vars = <String, Object?>{};
  final Set<String> _consts = <String>{};

  /// 最近的函数作用域（`var` 的归属地）。
  Scope get varScope => functionScope ? this : (parent?.varScope ?? this);

  bool has(String name) {
    Scope? s = this;
    while (s != null) {
      if (s._vars.containsKey(name)) return true;
      s = s.parent;
    }
    return false;
  }

  Object? lookup(String name) {
    Scope? s = this;
    while (s != null) {
      if (s._vars.containsKey(name)) return s._vars[name];
      s = s.parent;
    }
    return null;
  }

  bool contains(String name) => _vars.containsKey(name);

  void define(String name, Object? value, {bool isConst = false}) {
    _vars[name] = value;
    if (isConst) {
      _consts.add(name);
    } else {
      _consts.remove(name);
    }
  }

  bool isConst(String name) {
    Scope? s = this;
    while (s != null) {
      if (s._vars.containsKey(name)) return s._consts.contains(name);
      s = s.parent;
    }
    return false;
  }

  /// 赋值；找不到时定义在全局（sloppy mode 行为）。
  void assign(String name, Object? value) {
    Scope? s = this;
    while (s != null) {
      if (s._vars.containsKey(name)) {
        if (s._consts.contains(name)) {
          throw JsException('TypeError: 不能给常量 "$name" 重新赋值');
        }
        s._vars[name] = value;
        return;
      }
      s = s.parent;
    }
    varScope.define(name, value);
  }

  /// 只读全局名称列表，调试/Error 用。
  List<String> get names => _vars.keys.toList();
}
