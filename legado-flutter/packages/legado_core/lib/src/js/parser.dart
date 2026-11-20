import 'ast.dart';
import 'js_exception.dart';
import 'token.dart';

/// 手写递归下降 + 优先级爬升解析器。
///
/// 支持的是「书源里实际会出现的 JS 子集」，不是完整 ECMAScript：
/// 类、生成器、async/await、解构赋值、标签模板等会给出明确的语法错误，
/// 而不是悄悄按错误语义执行。
class Parser {
  Parser(String source) : _tokens = Lexer(source).tokenize(), _source = source;

  final List<Token> _tokens;
  final String _source;
  int _i = 0;
  bool _noIn = false;

  Program parseProgram() {
    final body = <Stmt>[];
    while (_cur.type != TokenType.eof) {
      body.add(_parseStatement());
    }
    return Program(body);
  }

  // --------------------------------------------------------------- helpers

  Token get _cur => _tokens[_i];
  Token get _prev => _tokens[_i > 0 ? _i - 1 : 0];

  Token _peek([int n = 1]) {
    final j = _i + n;
    return j < _tokens.length ? _tokens[j] : _tokens.last;
  }

  bool _is(String punct) => _cur.type == TokenType.punct && _cur.value == punct;
  bool _isKw(String kw) => _cur.type == TokenType.keyword && _cur.value == kw;

  void _advance() {
    if (_i < _tokens.length - 1) _i++;
  }

  Token _eat(String punct) {
    if (!_is(punct)) _error('期望 "$punct"，实际是 ${_describe(_cur)}');
    final t = _cur;
    _advance();
    return t;
  }

  Token _eatKw(String kw) {
    if (!_isKw(kw)) _error('期望关键字 "$kw"，实际是 ${_describe(_cur)}');
    final t = _cur;
    _advance();
    return t;
  }

  Never _error(String msg, [Token? at]) {
    final t = at ?? _cur;
    throw JsException(
      '语法错误: $msg',
      line: t.line,
      column: t.column,
      sourceLine: _lineOf(t.line),
      script: _source,
      isSyntax: true,
    );
  }

  String? _lineOf(int line) {
    final lines = _source.split('\n');
    if (line >= 1 && line <= lines.length) {
      final l = lines[line - 1];
      return l.endsWith('\r') ? l.substring(0, l.length - 1) : l;
    }
    return null;
  }

  static String _describe(Token t) {
    switch (t.type) {
      case TokenType.eof:
        return '文件结尾';
      case TokenType.string:
        return '字符串 ${t.value}';
      case TokenType.template:
        return '模板字符串';
      case TokenType.number:
        return '数字 ${t.value}';
      default:
        return '"${t.value}"';
    }
  }

  void _consumeSemicolon() {
    if (_is(';')) {
      _advance();
      return;
    }
    if (_cur.type == TokenType.eof) return;
    if (_is('}')) return;
    // 自动分号插入：换行即可结束。
    if (_cur.line > _prev.line) return;
    _error('期望 ";"，实际是 ${_describe(_cur)}');
  }

  // ------------------------------------------------------------- statements

  Stmt _parseStatement() {
    final t = _cur;
    if (_is(';')) {
      _advance();
      return EmptyStmt(t.line, t.column);
    }
    if (_is('{')) return _parseBlock();

    if (t.type == TokenType.keyword) {
      switch (t.value) {
        case 'var':
        case 'let':
        case 'const':
          final decl = _parseVarDecl(consumeSemi: true);
          return decl;
        case 'function':
          return _parseFunctionDecl();
        case 'if':
          return _parseIf();
        case 'for':
          return _parseFor();
        case 'while':
          return _parseWhile();
        case 'do':
          return _parseDoWhile();
        case 'switch':
          return _parseSwitch();
        case 'try':
          return _parseTry();
        case 'throw':
          _advance();
          final v = _parseExpression();
          _consumeSemicolon();
          return ThrowStmt(v, t.line, t.column);
        case 'return':
          _advance();
          Expr? value;
          if (!_is(';') &&
              !_is('}') &&
              _cur.type != TokenType.eof &&
              _cur.line == _prev.line) {
            value = _parseExpression();
          }
          _consumeSemicolon();
          return ReturnStmt(value, t.line, t.column);
        case 'async':
          _advance();
          if (_isKw('function')) return _parseFunctionDecl();
          if (_cur.type == TokenType.ident && _peek().isPunct('=>')) {
            final id = _cur;
            _advance();
            _advance();
            final arrow = _parseArrowBody(
                [Param(id.value as String, line: id.line, column: id.column)],
                id.line,
                id.column);
            return ExprStmt(arrow, t.line, t.column);
          }
          _error('async 只支持箭头函数或函数表达式');
        case 'break':
          _advance();
          String? breakLabel;
          if (_cur.type == TokenType.ident && _cur.line == _prev.line) {
            breakLabel = _cur.value as String;
            _advance();
          }
          _consumeSemicolon();
          return BreakStmt(breakLabel, t.line, t.column);
        case 'continue':
          _advance();
          String? continueLabel;
          if (_cur.type == TokenType.ident && _cur.line == _prev.line) {
            continueLabel = _cur.value as String;
            _advance();
          }
          _consumeSemicolon();
          return ContinueStmt(continueLabel, t.line, t.column);
        case 'class':
          _error('不支持 class 语法，书源脚本请改用对象字面量');
        case 'import':
        case 'export':
        case 'yield':
        case 'debugger':
          _error('不支持 "${t.value}" 语句');
      }
    }

    // label: statement
    if (t.type == TokenType.ident && _peek().isPunct(':')) {
      final label = t.value as String;
      _advance();
      _advance();
      final body = _parseStatement();
      return LabeledStmt(label, body, t.line, t.column);
    }

    return _parseExpressionStatement(t);
  }

  Stmt _parseExpressionStatement(Token t) {
    final expr = _parseExpression();
    _consumeSemicolon();
    return ExprStmt(expr, t.line, t.column);
  }

  BlockStmt _parseBlock() {
    final t = _eat('{');
    final body = <Stmt>[];
    while (!_is('}') && _cur.type != TokenType.eof) {
      body.add(_parseStatement());
    }
    _eat('}');
    return BlockStmt(body, t.line, t.column);
  }

  VarDeclStmt _parseVarDecl({required bool consumeSemi}) {
    final t = _cur;
    final kind = t.value as String;
    _advance();
    final decls = <VarDeclarator>[];
    while (true) {
      final nt = _cur;
      if (nt.type != TokenType.ident) {
        if (nt.isPunct('[') || nt.isPunct('{')) {
          _error('暂不支持解构声明，请拆成多个变量');
        }
        _error('变量声明后期望变量名，实际是 ${_describe(nt)}');
      }
      final name = nt.value as String;
      _advance();
      Expr? init;
      if (_is('=')) {
        _advance();
        init = _parseAssignment();
      }
      decls.add(VarDeclarator(name, init, nt.line, nt.column));
      if (_is(',')) {
        _advance();
        continue;
      }
      break;
    }
    if (consumeSemi) _consumeSemicolon();
    return VarDeclStmt(kind, decls, t.line, t.column);
  }

  FuncDecl _parseFunctionDecl() {
    final t = _eatKw('function');
    if (_is('*')) _error('不支持生成器函数');
    if (_cur.type != TokenType.ident) _error('函数声明缺少函数名');
    final name = _cur.value as String;
    _advance();
    final params = _parseParams();
    final body = _parseFunctionBody();
    return FuncDecl(name, params, body, t.line, t.column);
  }

  List<Param> _parseParams() {
    _eat('(');
    final params = <Param>[];
    while (!_is(')')) {
      final t = _cur;
      if (_is('...')) {
        _advance();
        if (_cur.type != TokenType.ident) _error('剩余参数缺少名字');
        final name = _cur.value as String;
        _advance();
        params.add(Param(name, rest: true, line: t.line, column: t.column));
      } else if (t.type == TokenType.ident) {
        _advance();
        Expr? def;
        if (_is('=')) {
          _advance();
          def = _parseAssignment();
        }
        params.add(Param(t.value as String, defaultValue: def, line: t.line, column: t.column));
      } else if (t.isPunct('[') || t.isPunct('{')) {
        _error('暂不支持解构参数');
      } else {
        _error('参数列表中出现 ${_describe(t)}');
      }
      if (_is(',')) {
        _advance();
        continue;
      }
      break;
    }
    _eat(')');
    return params;
  }

  List<Stmt> _parseFunctionBody() {
    final block = _parseBlock();
    return block.body;
  }

  IfStmt _parseIf() {
    final t = _eatKw('if');
    _eat('(');
    final test = _parseExpression();
    _eat(')');
    final cons = _parseStatement();
    Stmt? alt;
    if (_isKw('else')) {
      _advance();
      alt = _parseStatement();
    }
    return IfStmt(test, cons, alt, t.line, t.column);
  }

  Stmt _parseFor() {
    final t = _eatKw('for');
    _eat('(');

    String? declKind;
    Node? init;
    Expr? initExpr;

    if (_is(';')) {
      // 无初始化
    } else if (_isKw('var') || _isKw('let') || _isKw('const')) {
      declKind = _cur.value as String;
      final saved = _noIn;
      _noIn = true;
      final decl = _parseVarDecl(consumeSemi: false);
      _noIn = saved;
      init = decl;
    } else {
      final saved = _noIn;
      _noIn = true;
      initExpr = _parseExpression();
      _noIn = saved;
    }

    if (_isKw('in') || _isKw('of')) {
      final isOf = _isKw('of');
      _advance();
      final right = _parseExpression();
      _eat(')');
      Expr left;
      if (declKind != null) {
        final decl = init as VarDeclStmt;
        if (decl.decls.length != 1) _error('for...in/of 只能声明一个变量');
        final d = decl.decls.first;
        left = Ident(d.name, d.line, d.column);
        if (d.init != null) _error('for...in/of 的声明不能带初始值');
      } else {
        left = initExpr!;
      }
      final body = _parseStatement();
      return ForInStmt(
        declKind: declKind,
        left: left,
        isOf: isOf,
        right: right,
        body: body,
        line: t.line,
        column: t.column,
      );
    }

    _eat(';');
    Expr? test;
    if (!_is(';')) test = _parseExpression();
    _eat(';');
    Expr? update;
    if (!_is(')')) update = _parseExpression();
    _eat(')');
    final body = _parseStatement();
    return ForStmt(init ?? (initExpr == null ? null : ExprStmt(initExpr, t.line, t.column)),
        test, update, body, t.line, t.column);
  }

  WhileStmt _parseWhile() {
    final t = _eatKw('while');
    _eat('(');
    final test = _parseExpression();
    _eat(')');
    final body = _parseStatement();
    return WhileStmt(test, body, t.line, t.column);
  }

  DoWhileStmt _parseDoWhile() {
    final t = _eatKw('do');
    final body = _parseStatement();
    _eatKw('while');
    _eat('(');
    final test = _parseExpression();
    _eat(')');
    if (_is(';')) _advance();
    return DoWhileStmt(body, test, t.line, t.column);
  }

  SwitchStmt _parseSwitch() {
    final t = _eatKw('switch');
    _eat('(');
    final disc = _parseExpression();
    _eat(')');
    _eat('{');
    final cases = <SwitchCase>[];
    while (!_is('}') && _cur.type != TokenType.eof) {
      final ct = _cur;
      Expr? test;
      if (_isKw('case')) {
        _advance();
        test = _parseExpression();
        _eat(':');
      } else if (_isKw('default')) {
        _advance();
        _eat(':');
      } else {
        _error('switch 里只能是 case/default，实际是 ${_describe(_cur)}');
      }
      final body = <Stmt>[];
      while (!_isKw('case') && !_isKw('default') && !_is('}') && _cur.type != TokenType.eof) {
        body.add(_parseStatement());
      }
      cases.add(SwitchCase(test, body, ct.line, ct.column));
    }
    _eat('}');
    return SwitchStmt(disc, cases, t.line, t.column);
  }

  TryStmt _parseTry() {
    final t = _eatKw('try');
    final block = _parseBlock();
    String? catchParam;
    BlockStmt? catchBlock;
    BlockStmt? finallyBlock;
    if (_isKw('catch')) {
      _advance();
      if (_is('(')) {
        _advance();
        if (_cur.type != TokenType.ident) _error('catch 参数必须是标识符');
        catchParam = _cur.value as String;
        _advance();
        _eat(')');
      }
      catchBlock = _parseBlock();
    }
    if (_isKw('finally')) {
      _advance();
      finallyBlock = _parseBlock();
    }
    if (catchBlock == null && finallyBlock == null) {
      _error('try 必须跟 catch 或 finally');
    }
    return TryStmt(
      block: block,
      catchParam: catchParam,
      catchBlock: catchBlock,
      finallyBlock: finallyBlock,
      line: t.line,
      column: t.column,
    );
  }

  // ------------------------------------------------------------ expressions

  Expr _parseExpression() {
    var expr = _parseAssignment();
    if (_is(',')) {
      final exprs = <Expr>[expr];
      while (_is(',')) {
        _advance();
        exprs.add(_parseAssignment());
      }
      expr = SequenceExpr(exprs, expr.line, expr.column);
    }
    return expr;
  }

  static const Map<String, int> _binaryPrec = {
    '??': 3,
    '||': 4,
    '&&': 5,
    '|': 6,
    '^': 7,
    '&': 8,
    '==': 9,
    '!=': 9,
    '===': 9,
    '!==': 9,
    '<': 10,
    '>': 10,
    '<=': 10,
    '>=': 10,
    'instanceof': 10,
    'in': 10,
    '<<': 11,
    '>>': 11,
    '>>>': 11,
    '+': 12,
    '-': 12,
    '*': 13,
    '/': 13,
    '%': 13,
    '**': 14,
  };

  static const Set<String> _assignOps = {
    '=', '+=', '-=', '*=', '/=', '%=', '<<=', '>>=', '>>>=', '&=', '|=', '^=', '**=',
  };

  Expr _parseAssignment() {
    final left = _parseConditional();

    // 单参数箭头函数：x => ...
    if (_is('=>') && left is Ident) {
      _advance();
      return _parseArrowBody(
          [Param(left.name, line: left.line, column: left.column)], left.line, left.column);
    }

    if (_cur.type == TokenType.punct && _assignOps.contains(_cur.value)) {
      final op = _cur.value as String;
      final t = _cur;
      _advance();
      final right = _parseAssignment();
      if (left is! Ident && left is! MemberExpr) {
        _error('赋值号左边不是可赋值的表达式', t);
      }
      return AssignExpr(op, left, right, t.line, t.column);
    }
    return left;
  }

  Expr _parseConditional() {
    final test = _parseBinary(3);
    if (_is('?')) {
      final t = _cur;
      _advance();
      final cons = _parseAssignment();
      _eat(':');
      final alt = _parseAssignment();
      return ConditionalExpr(test, cons, alt, t.line, t.column);
    }
    return test;
  }

  String? _binaryOp(Token t) {
    if (t.type == TokenType.punct) {
      final v = t.value as String;
      if (_binaryPrec.containsKey(v)) return v;
      return null;
    }
    if (t.type == TokenType.keyword) {
      final v = t.value as String;
      if (v == 'instanceof' || v == 'in') {
        if (v == 'in' && _noIn) return null;
        return v;
      }
    }
    return null;
  }

  Expr _parseBinary(int minPrec) {
    var left = _parseUnary();
    while (true) {
      final op = _binaryOp(_cur);
      if (op == null) break;
      final prec = _binaryPrec[op]!;
      if (prec < minPrec) break;
      final t = _cur;
      _advance();
      final right = _parseBinary(op == '**' ? prec : prec + 1);
      if (op == '&&' || op == '||' || op == '??') {
        left = LogicalExpr(op, left, right, t.line, t.column);
      } else {
        left = BinaryExpr(op, left, right, t.line, t.column);
      }
    }
    return left;
  }

  Expr _parseUnary() {
    final t = _cur;
    if (t.type == TokenType.punct) {
      final v = t.value as String;
      if (v == '!' || v == '~' || v == '+' || v == '-') {
        _advance();
        final arg = _parseUnary();
        return UnaryExpr(v, arg, t.line, t.column);
      }
      if (v == '++' || v == '--') {
        _advance();
        final arg = _parseUnary();
        if (arg is! Ident && arg is! MemberExpr) _error('$v 需要可赋值的目标', t);
        return UpdateExpr(v, arg, prefix: true, line: t.line, column: t.column);
      }
    }
    if (t.type == TokenType.keyword) {
      final v = t.value as String;
      if (v == 'typeof' || v == 'void' || v == 'delete') {
        _advance();
        final arg = _parseUnary();
        return UnaryExpr(v, arg, t.line, t.column);
      }
      if (v == 'await') {
        _advance();
        // 同步执行语义下 await 等价于透明等待
        return _parseUnary();
      }
    }
    return _parsePostfix();
  }

  Expr _parsePostfix() {
    final expr = _parseCallMember();
    final t = _cur;
    if (t.isPunct('++') || t.isPunct('--')) {
      if (expr is Ident || expr is MemberExpr) {
        _advance();
        return UpdateExpr(t.value as String, expr, prefix: false, line: t.line, column: t.column);
      }
    }
    return expr;
  }

  Expr _parseCallMember() {
    Expr expr;
    if (_isKw('new')) {
      final t = _cur;
      _advance();
      if (_is('.')) _error('不支持 new.target');
      Expr callee = _parsePrimary();
      // new 的成员访问优先于参数列表
      while (true) {
        if (_is('.')) {
          _advance();
          callee = _memberFromIdent(callee);
        } else if (_is('[')) {
          _advance();
          final prop = _parseExpression();
          _eat(']');
          callee = MemberExpr(callee, prop,
              computed: true, optional: false, line: t.line, column: t.column);
        } else {
          break;
        }
      }
      final args = _is('(') ? _parseArguments() : <Expr>[];
      expr = NewExpr(callee, args, t.line, t.column);
    } else {
      expr = _parsePrimary();
    }

    return _finishPostfix(expr);
  }

  Expr _finishPostfix(Expr expr) {
    while (true) {
      final t = _cur;
      if (_is('.')) {
        _advance();
        expr = _memberFromIdent(expr);
      } else if (_is('?.')) {
        _advance();
        if (_is('(')) {
          final args = _parseArguments();
          expr = CallExpr(expr, args, optional: true, line: t.line, column: t.column);
        } else if (_is('[')) {
          _advance();
          final prop = _parseExpression();
          _eat(']');
          expr = MemberExpr(expr, prop,
              computed: true, optional: true, line: t.line, column: t.column);
        } else {
          expr = _memberFromIdent(expr, optional: true);
        }
      } else if (_is('[')) {
        _advance();
        final prop = _parseExpression();
        _eat(']');
        expr = MemberExpr(expr, prop,
            computed: true, optional: false, line: t.line, column: t.column);
      } else if (_is('(')) {
        final args = _parseArguments();
        expr = CallExpr(expr, args, optional: false, line: t.line, column: t.column);
      } else {
        break;
      }
    }
    return expr;
  }

  MemberExpr _memberFromIdent(Expr object, {bool optional = false}) {
    final t = _cur;
    if (t.type != TokenType.ident && t.type != TokenType.keyword) {
      _error('"." 后期望属性名，实际是 ${_describe(t)}');
    }
    _advance();
    return MemberExpr(object, t.value as String,
        computed: false, optional: optional, line: t.line, column: t.column);
  }

  List<Expr> _parseArguments() {
    _eat('(');
    final args = <Expr>[];
    while (!_is(')')) {
      final t = _cur;
      if (_is('...')) {
        _advance();
        final arg = _parseAssignment();
        args.add(SpreadExpr(arg, t.line, t.column));
      } else {
        args.add(_parseAssignment());
      }
      if (_is(',')) {
        _advance();
        continue;
      }
      break;
    }
    _eat(')');
    return args;
  }

  Expr _parsePrimary() {
    final t = _cur;
    switch (t.type) {
      case TokenType.number:
        _advance();
        return NumLit(t.value as num, t.line, t.column);
      case TokenType.string:
        _advance();
        return StrLit(t.value as String, t.line, t.column);
      case TokenType.regex:
        _advance();
        final text = t.value as String;
        final lastSlash = text.lastIndexOf('/');
        final pattern = text.substring(1, lastSlash);
        final flags = text.substring(lastSlash + 1);
        return RegexLit(pattern, flags, t.line, t.column);
      case TokenType.template:
        _advance();
        final rawParts = t.parts ?? const <Object>[];
        final parts = <Object>[];
        for (final p in rawParts) {
          if (p is String) {
            parts.add(p);
          } else if (p is List<Token>) {
            final sub = Parser('');
            sub._tokens.clear();
            sub._tokens.addAll(p);
            sub._tokens.add(Token(TokenType.eof, null, line: t.line, column: t.column));
            parts.add(sub._parseExpression());
          }
        }
        return TemplateLit(parts, t.line, t.column);
      case TokenType.ident:
        _advance();
        return Ident(t.value as String, t.line, t.column);
      case TokenType.keyword:
        final v = t.value as String;
        switch (v) {
          case 'true':
          case 'false':
            _advance();
            return BoolLit(v == 'true', t.line, t.column);
          case 'null':
            _advance();
            return NullLit(t.line, t.column);
          case 'this':
            _advance();
            return ThisExpr(t.line, t.column);
          case 'function':
            return _parseFunctionExpr();
          case 'new':
            return _parseCallMember();
          case 'class':
            _error('不支持 class 语法，书源脚本请改用对象字面量');
          case 'super':
            _error('不支持 super');
          case 'async':
            _advance();
            if (_isKw('function')) return _parseFunctionExpr();
            if (_cur.type == TokenType.ident && _peek().isPunct('=>')) {
              final id = _cur;
              _advance();
              _advance();
              return _parseArrowBody(
                  [Param(id.value as String, line: id.line, column: id.column)],
                  id.line,
                  id.column);
            }
            _error('async 只支持箭头函数或函数表达式');
        }
        _error('关键字 "${t.value}" 不能出现在表达式位置');
      case TokenType.punct:
        if (t.value == '(') return _parseParenOrArrow();
        if (t.value == '[') return _parseArrayLit();
        if (t.value == '{') return _parseObjectLit();
        if (t.value == '...') _error('展开运算符只能用于数组/对象/调用参数');
        _error('表达式位置出现 "${t.value}"');
      case TokenType.eof:
        _error('表达式意外结束');
    }
  }

  Expr _parseParenOrArrow() {
    final start = _i;
    if (_looksLikeArrowParams()) {
      final params = _parseParams();
      _eat('=>');
      final startToken = _tokens[start];
      return _parseArrowBody(params, startToken.line, startToken.column);
    }
    final t = _eat('(');
    if (_is(')')) {
      _error('空括号不是合法表达式', t);
    }
    final expr = _parseExpression();
    _eat(')');
    return expr;
  }

  /// 从当前 '(' 向后找到配对的 ')'，看后面是不是 '=>'。
  bool _looksLikeArrowParams() {
    var depth = 0;
    var j = _i;
    while (j < _tokens.length) {
      final t = _tokens[j];
      if (t.type == TokenType.eof) return false;
      if (t.isPunct('(') || t.isPunct('[') || t.isPunct('{')) depth++;
      if (t.isPunct(')') || t.isPunct(']') || t.isPunct('}')) {
        depth--;
        if (depth == 0) {
          final next = j + 1 < _tokens.length ? _tokens[j + 1] : _tokens.last;
          return next.isPunct('=>');
        }
      }
      j++;
    }
    return false;
  }

  Expr _parseArrowBody(List<Param> params, int line, int column) {
    if (_is('{')) {
      final body = _parseFunctionBody();
      return ArrowFn(params, body, false, line, column);
    }
    final expr = _parseAssignment();
    return ArrowFn(params, expr, true, line, column);
  }

  FuncExpr _parseFunctionExpr() {
    final t = _eatKw('function');
    if (_is('*')) _error('不支持生成器函数');
    String? name;
    if (_cur.type == TokenType.ident) {
      name = _cur.value as String;
      _advance();
    }
    final params = _parseParams();
    final body = _parseFunctionBody();
    return FuncExpr(name, params, body, t.line, t.column);
  }

  ArrayLit _parseArrayLit() {
    final t = _eat('[');
    final elements = <Expr?>[];
    while (!_is(']')) {
      if (_is(',')) {
        _advance();
        elements.add(null);
        continue;
      }
      final et = _cur;
      if (_is('...')) {
        _advance();
        final arg = _parseAssignment();
        elements.add(SpreadExpr(arg, et.line, et.column));
      } else {
        elements.add(_parseAssignment());
      }
      if (_is(',')) {
        _advance();
        continue;
      }
      break;
    }
    _eat(']');
    return ArrayLit(elements, t.line, t.column);
  }

  ObjectLit _parseObjectLit() {
    final t = _eat('{');
    final props = <ObjProp>[];
    while (!_is('}')) {
      final pt = _cur;

      if (_is('...')) {
        _advance();
        final arg = _parseAssignment();
        props.add(ObjProp(value: SpreadExpr(arg, pt.line, pt.column), line: pt.line, column: pt.column));
      } else {
        String? key;
        Expr? computed;
        if (_is('[')) {
          _advance();
          computed = _parseExpression();
          _eat(']');
        } else if (pt.type == TokenType.ident || pt.type == TokenType.keyword) {
          key = pt.value as String;
          _advance();
        } else if (pt.type == TokenType.string) {
          key = pt.value as String;
          _advance();
        } else if (pt.type == TokenType.number) {
          key = pt.value.toString();
          _advance();
        } else {
          _error('对象字面量里的键不合法: ${_describe(pt)}');
        }

        if (_is(':')) {
          _advance();
          final value = _parseAssignment();
          props.add(ObjProp(key: key, computedKey: computed, value: value,
              line: pt.line, column: pt.column));
        } else if (_is('(')) {
          // 方法简写 { foo(a) { ... } }
          final params = _parseParams();
          final body = _parseFunctionBody();
          final fn = FuncExpr(key, params, body, pt.line, pt.column);
          props.add(ObjProp(key: key, computedKey: computed, value: fn,
              line: pt.line, column: pt.column));
        } else if (key != null) {
          // 简写 { a, b }
          props.add(ObjProp(
              key: key,
              value: Ident(key, pt.line, pt.column),
              line: pt.line,
              column: pt.column));
        } else {
          _error('对象字面量的计算属性缺少 ":"');
        }
      }

      if (_is(',')) {
        _advance();
        continue;
      }
      break;
    }
    _eat('}');
    return ObjectLit(props, t.line, t.column);
  }
}
