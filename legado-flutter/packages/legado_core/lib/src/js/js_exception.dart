/// 书源脚本执行错误。
///
/// 调试书源时最痛的不是报错，而是不知道为什么报错。所以这里强制携带
/// 行列号与出错那一行的源码文本，`toString()` 直接输出形如：
///
/// ```
/// JsException: 第 3 行: var a = obj.foo.bar;
///                           ^
///   Cannot read property 'bar' of undefined
/// ```
class JsException implements Exception {
  JsException(
    this.message, {
    this.line,
    this.column,
    this.sourceLine,
    this.script,
    this.isSyntax = false,
  });

  /// 面向人的错误描述，不带位置信息。
  final String message;

  /// 1 起始的行号。
  final int? line;

  /// 1 起始的列号。
  final int? column;

  /// 出错那行的源码文本（未 trim）。
  final String? sourceLine;

  /// 完整脚本，便于上层展示上下文。
  final String? script;

  /// 是否是解析期错误（语法错误 vs 运行时错误）。
  final bool isSyntax;

  /// 补全位置信息（引擎在最外层捕获后回填，避免每层都传 script）。
  JsException withLocation({
    int? line,
    int? column,
    String? sourceLine,
    String? script,
  }) {
    return JsException(
      message,
      line: this.line ?? line,
      column: this.column ?? column,
      sourceLine: this.sourceLine ?? sourceLine,
      script: this.script ?? script,
      isSyntax: isSyntax,
    );
  }

  @override
  String toString() {
    final buf = StringBuffer();
    if (line != null) {
      buf.write('第 $line 行');
      if (column != null) buf.write(' 第 $column 列');
      buf.write(': ');
    }
    if (sourceLine != null) {
      buf.write(sourceLine);
      buf.write('\n');
      final col = column;
      if (col != null && col > 0) {
        // 用显示宽度对齐：Tab 当作一个字符，够用。
        buf.write(' ' * (col - 1));
        buf.write('^');
        buf.write('\n');
      }
      buf.write('  ');
    }
    buf.write(message);
    return buf.toString();
  }
}

/// 从 [script] 中取出第 [line] 行（1 起始）。
String? sourceLineOf(String script, int? line) {
  if (line == null || line < 1) return null;
  var cur = 1;
  var start = 0;
  for (var i = 0; i < script.length; i++) {
    if (cur == line) {
      var end = script.indexOf('\n', start);
      if (end < 0) end = script.length;
      var text = script.substring(start, end);
      if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
      return text;
    }
    if (script.codeUnitAt(i) == 0x0A) {
      cur++;
      start = i + 1;
    }
  }
  if (cur == line && start <= script.length) {
    return script.substring(start);
  }
  return null;
}
