import 'js_exception.dart';

/// 词法单元类别。
enum TokenType {
  eof,
  number,
  string,
  template,
  regex,
  ident,
  keyword,
  punct,
}

/// 词法单元。
class Token {
  Token(
    this.type,
    this.value, {
    required this.line,
    required this.column,
    this.parts,
  });

  final TokenType type;

  /// number → num；string → 解码后的字符串；regex → JS 字面量文本（含斜杠）；
  /// ident/keyword/punct → 原始文本。
  final Object? value;

  final int line;
  final int column;

  /// 模板字符串的片段：String 或 `List<Token>`（`${}` 里的表达式）。
  final List<Object>? parts;

  bool isPunct(String s) => type == TokenType.punct && value == s;
  bool isKeyword(String s) => type == TokenType.keyword && value == s;

  @override
  String toString() => '${type.name}($value)@$line:$column';
}

const Set<String> _keywords = {
  'var', 'let', 'const', 'function', 'return', 'if', 'else', 'for', 'while',
  'do', 'break', 'continue', 'switch', 'case', 'default', 'try', 'catch',
  'finally', 'throw', 'new', 'delete', 'typeof', 'instanceof', 'in', 'of',
  'void', 'this', 'null', 'true', 'false', 'class', 'extends', 'super',
  'yield', 'async', 'await', 'debugger', 'export', 'import',
};

/// 可以出现在表达式末尾、从而让后续 `/` 被解释为除法的关键字。
const Set<String> _valueKeywords = {'this', 'null', 'true', 'false', 'super'};

const List<String> _puncts = [
  '>>>=', '===', '!==', '**=', '<<=', '>>=', '>>>', '...', '=>', '==', '!=',
  '<=', '>=', '&&', '||', '??', '?.', '++', '--', '+=', '-=', '*=', '/=',
  '%=', '&=', '|=', '^=', '<<', '>>', '**', '{', '}', '(', ')', '[', ']',
  ';', ',', '<', '>', '+', '-', '*', '/', '%', '&', '|', '^', '!', '~', '?',
  ':', '=', '.',
];

/// 手写词法分析器。不做任何预处理，直接在源码上扫描。
class Lexer {
  Lexer(String source, {int line = 1, int column = 1})
      : _src = source,
        _line = line,
        _col = column;

  final String _src;
  int _pos = 0;
  int _line;
  int _col;
  Token? _prev;

  /// 一次性切完所有 token（含末尾 eof）。
  List<Token> tokenize() {
    final out = <Token>[];
    while (true) {
      final t = next();
      out.add(t);
      if (t.type == TokenType.eof) break;
    }
    return out;
  }

  Token next() {
    _skipTrivia();
    if (_pos >= _src.length) {
      return Token(TokenType.eof, null, line: _line, column: _col);
    }
    final ch = _src[_pos];
    final line = _line;
    final col = _col;

    Token tok;
    if (_isDigit(ch) || (ch == '.' && _pos + 1 < _src.length && _isDigit(_src[_pos + 1]))) {
      tok = _number(line, col);
    } else if (ch == '"' || ch == "'") {
      tok = _string(ch, line, col);
    } else if (ch == '`') {
      tok = _template(line, col);
    } else if (_isIdentStart(ch)) {
      tok = _ident(line, col);
    } else if (ch == '/' && _regexAllowed()) {
      tok = _regex(line, col);
    } else {
      tok = _punct(line, col);
    }
    _prev = tok;
    return tok;
  }

  // ---------------------------------------------------------------- trivia

  void _skipTrivia() {
    while (_pos < _src.length) {
      final ch = _src[_pos];
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' ||
          ch == '\u00A0' || ch == '\uFEFF') {
        _advance();
        continue;
      }
      if (ch == '/' && _pos + 1 < _src.length) {
        final nx = _src[_pos + 1];
        if (nx == '/') {
          while (_pos < _src.length && _src[_pos] != '\n') {
            _advance();
          }
          continue;
        }
        if (nx == '*') {
          _advance();
          _advance();
          while (_pos < _src.length) {
            if (_src[_pos] == '*' && _pos + 1 < _src.length && _src[_pos + 1] == '/') {
              _advance();
              _advance();
              break;
            }
            _advance();
          }
          continue;
        }
      }
      break;
    }
  }

  void _advance() {
    if (_pos >= _src.length) return;
    if (_src[_pos] == '\n') {
      _line++;
      _col = 1;
    } else {
      _col++;
    }
    _pos++;
  }

  static bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  static bool _isIdentStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x41 && u <= 0x5A) ||
        (u >= 0x61 && u <= 0x7A) ||
        u == 0x24 || u == 0x5F ||
        u > 0x7F;
  }

  static bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);

  // --------------------------------------------------------------- scanners

  Token _number(int line, int col) {
    final start = _pos;
    if (_src[_pos] == '0' && _pos + 1 < _src.length) {
      final p = _src[_pos + 1].toLowerCase();
      if (p == 'x' || p == 'b' || p == 'o') {
        _advance();
        _advance();
        while (_pos < _src.length && _isIdentPart(_src[_pos])) {
          _advance();
        }
        final text = _src.substring(start, _pos);
        final radix = p == 'x' ? 16 : (p == 'b' ? 2 : 8);
        final digits = text.substring(2);
        final value = int.tryParse(digits, radix: radix);
        if (value == null) {
          throw JsException('非法数字字面量 "$text"', line: line, column: col, isSyntax: true);
        }
        return Token(TokenType.number, value, line: line, column: col);
      }
    }
    var seenDot = false;
    var seenExp = false;
    while (_pos < _src.length) {
      final c = _src[_pos];
      if (_isDigit(c)) {
        _advance();
      } else if (c == '.' && !seenDot && !seenExp) {
        seenDot = true;
        _advance();
      } else if ((c == 'e' || c == 'E') && !seenExp) {
        seenExp = true;
        _advance();
        if (_pos < _src.length && (_src[_pos] == '+' || _src[_pos] == '-')) {
          _advance();
        }
      } else {
        break;
      }
    }
    final text = _src.substring(start, _pos);
    if (!seenDot && !seenExp) {
      final i = int.tryParse(text);
      if (i != null) return Token(TokenType.number, i, line: line, column: col);
    }
    final d = double.tryParse(text);
    if (d == null) {
      throw JsException('非法数字字面量 "$text"', line: line, column: col, isSyntax: true);
    }
    return Token(TokenType.number, d, line: line, column: col);
  }

  Token _string(String quote, int line, int col) {
    _advance(); // 开引号
    final buf = StringBuffer();
    while (true) {
      if (_pos >= _src.length) {
        throw JsException('字符串未闭合', line: line, column: col, isSyntax: true);
      }
      final c = _src[_pos];
      if (c == quote) {
        _advance();
        break;
      }
      if (c == '\\') {
        _advance();
        _readEscape(buf, line, col);
        continue;
      }
      if (c == '\n') {
        throw JsException('字符串中出现换行（请用 \\n 或模板字符串）',
            line: _line, column: _col, isSyntax: true);
      }
      buf.write(c);
      _advance();
    }
    return Token(TokenType.string, buf.toString(), line: line, column: col);
  }

  void _readEscape(StringBuffer buf, int line, int col) {
    if (_pos >= _src.length) return;
    final c = _src[_pos];
    _advance();
    switch (c) {
      case 'n':
        buf.write('\n');
        break;
      case 't':
        buf.write('\t');
        break;
      case 'r':
        buf.write('\r');
        break;
      case 'b':
        buf.write('\b');
        break;
      case 'f':
        buf.write('\f');
        break;
      case 'v':
        buf.write('\v');
        break;
      case '0':
        buf.write('\x00');
        break;
      case 'x':
        buf.write(_readHex(2, line, col));
        break;
      case 'u':
        if (_pos < _src.length && _src[_pos] == '{') {
          _advance();
          final start = _pos;
          while (_pos < _src.length && _src[_pos] != '}') {
            _advance();
          }
          final hex = _src.substring(start, _pos);
          if (_pos < _src.length) _advance();
          final code = int.tryParse(hex, radix: 16);
          if (code == null) {
            throw JsException('非法 \\u{...} 转义', line: line, column: col, isSyntax: true);
          }
          buf.writeCharCode(code);
        } else {
          buf.write(_readHex(4, line, col));
        }
        break;
      case '\n':
        // 续行
        break;
      default:
        buf.write(c);
    }
  }

  String _readHex(int n, int line, int col) {
    if (_pos + n > _src.length) {
      throw JsException('非法转义序列', line: line, column: col, isSyntax: true);
    }
    final hex = _src.substring(_pos, _pos + n);
    final code = int.tryParse(hex, radix: 16);
    if (code == null) {
      throw JsException('非法转义序列 "\\$hex"', line: line, column: col, isSyntax: true);
    }
    for (var i = 0; i < n; i++) {
      _advance();
    }
    return String.fromCharCode(code);
  }

  Token _ident(int line, int col) {
    final start = _pos;
    while (_pos < _src.length && _isIdentPart(_src[_pos])) {
      _advance();
    }
    final text = _src.substring(start, _pos);
    return Token(
      _keywords.contains(text) ? TokenType.keyword : TokenType.ident,
      text,
      line: line,
      column: col,
    );
  }

  Token _regex(int line, int col) {
    final start = _pos;
    _advance(); // '/'
    var inClass = false;
    while (true) {
      if (_pos >= _src.length) {
        throw JsException('正则字面量未闭合', line: line, column: col, isSyntax: true);
      }
      final c = _src[_pos];
      if (c == '\n') {
        throw JsException('正则字面量中出现换行', line: line, column: col, isSyntax: true);
      }
      if (c == '\\') {
        _advance();
        _advance();
        continue;
      }
      if (c == '[') {
        inClass = true;
      } else if (c == ']') {
        inClass = false;
      } else if (c == '/' && !inClass) {
        _advance();
        break;
      }
      _advance();
    }
    while (_pos < _src.length && _isIdentPart(_src[_pos])) {
      _advance();
    }
    final text = _src.substring(start, _pos);
    return Token(TokenType.regex, text, line: line, column: col);
  }

  Token _template(int line, int col) {
    _advance(); // '`'
    final parts = <Object>[];
    final buf = StringBuffer();
    while (true) {
      if (_pos >= _src.length) {
        throw JsException('模板字符串未闭合', line: line, column: col, isSyntax: true);
      }
      final c = _src[_pos];
      if (c == '`') {
        _advance();
        break;
      }
      if (c == '\\') {
        _advance();
        _readEscape(buf, line, col);
        continue;
      }
      if (c == r'$' && _pos + 1 < _src.length && _src[_pos + 1] == '{') {
        _advance();
        _advance();
        parts.add(buf.toString());
        buf.clear();
        final exprStart = _pos;
        final exprLine = _line;
        final exprCol = _col;
        _skipBalancedBrace();
        final exprText = _src.substring(exprStart, _pos);
        if (_pos < _src.length) _advance(); // 吃掉 '}'
        final sub = Lexer(exprText, line: exprLine, column: exprCol).tokenize();
        sub.removeWhere((t) => t.type == TokenType.eof);
        parts.add(sub);
        continue;
      }
      buf.write(c);
      _advance();
    }
    parts.add(buf.toString());
    return Token(TokenType.template, null, line: line, column: col, parts: parts);
  }

  /// 从 `${` 之后扫描到配对的 `}`（不消费 `}`）。
  void _skipBalancedBrace() {
    var depth = 1;
    while (_pos < _src.length) {
      final c = _src[_pos];
      if (c == '"' || c == "'") {
        _advance();
        while (_pos < _src.length && _src[_pos] != c) {
          if (_src[_pos] == '\\') _advance();
          _advance();
        }
        _advance();
        continue;
      }
      if (c == '`') {
        _advance();
        // 跳过嵌套模板，允许其中再次出现 ${}
        var nested = 0;
        while (_pos < _src.length) {
          final d = _src[_pos];
          if (d == '\\') {
            _advance();
            _advance();
            continue;
          }
          if (d == r'$' && _pos + 1 < _src.length && _src[_pos + 1] == '{') {
            nested++;
            _advance();
            _advance();
            continue;
          }
          if (d == '}' && nested > 0) {
            nested--;
            _advance();
            continue;
          }
          if (d == '`' && nested == 0) {
            _advance();
            break;
          }
          _advance();
        }
        continue;
      }
      if (c == '{') {
        depth++;
        _advance();
        continue;
      }
      if (c == '}') {
        depth--;
        if (depth == 0) return;
        _advance();
        continue;
      }
      _advance();
    }
  }

  Token _punct(int line, int col) {
    for (final p in _puncts) {
      if (_src.startsWith(p, _pos)) {
        // `?.5` 应被当成 `?` + `.5`
        if (p == '?.' && _pos + 2 < _src.length && _isDigit(_src[_pos + 2])) {
          continue;
        }
        for (var i = 0; i < p.length; i++) {
          _advance();
        }
        return Token(TokenType.punct, p, line: line, column: col);
      }
    }
    throw JsException('无法识别的字符 "${_src[_pos]}"',
        line: line, column: col, isSyntax: true);
  }

  bool _regexAllowed() {
    final prev = _prev;
    if (prev == null) return true;
    switch (prev.type) {
      case TokenType.number:
      case TokenType.string:
      case TokenType.template:
      case TokenType.regex:
      case TokenType.ident:
        return false;
      case TokenType.keyword:
        return !_valueKeywords.contains(prev.value);
      case TokenType.punct:
        final v = prev.value;
        return !(v == ')' || v == ']' || v == '++' || v == '--');
      case TokenType.eof:
        return true;
    }
  }
}
