import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'interpreter.dart';
import 'scope.dart';
import 'values.dart';

// ===========================================================================
// 正则辅助（interpreter.dart 里 JsRegExp.test/exec 用到）
// ===========================================================================

Object? regexTest(Interpreter it, JsRegExp re, List<Object?> args) {
  final s = args.isEmpty ? 'undefined' : jsToString(args[0]);
  if (re.global || re.sticky) {
    if (re.lastIndex > s.length) {
      re.lastIndex = 0;
      return false;
    }
    final m = re.sticky
        ? _matchAtStart(re.regExp, s, re.lastIndex)
        : _firstMatchFrom(re.regExp, s, re.lastIndex);
    if (m == null) {
      re.lastIndex = 0;
      return false;
    }
    re.lastIndex = m.end;
    return true;
  }
  return re.regExp.hasMatch(s);
}

Object? regexExec(Interpreter it, JsRegExp re, List<Object?> args) {
  final s = args.isEmpty ? 'undefined' : jsToString(args[0]);
  RegExpMatch? m;
  if (re.global || re.sticky) {
    if (re.lastIndex > s.length) {
      re.lastIndex = 0;
      return null;
    }
    m = re.sticky
        ? _matchAtStart(re.regExp, s, re.lastIndex)
        : _firstMatchFrom(re.regExp, s, re.lastIndex);
    if (m == null) {
      re.lastIndex = 0;
      return null;
    }
    re.lastIndex = m.end;
  } else {
    m = re.regExp.firstMatch(s);
  }
  if (m == null) return null;
  return _matchToArray(m, s);
}

RegExpMatch? _firstMatchFrom(RegExp re, String s, int start) {
  if (start < 0) start = 0;
  for (final m in re.allMatches(s, start)) {
    return m;
  }
  return null;
}

RegExpMatch? _matchAtStart(RegExp re, String s, int start) {
  final m = re.matchAsPrefix(s, start);
  return m is RegExpMatch ? m : null;
}

JsArray _matchToArray(RegExpMatch m, String s) {
  final list = JsArray()..props['index'] = m.start;
  list.props['input'] = s;
  list.add(m.group(0));
  for (var i = 1; i <= m.groupCount; i++) {
    list.add(m.group(i));
  }
  return list;
}

// ===========================================================================
// String 实例方法
// ===========================================================================

Map<String, NativeFunction> createStringMethods(Interpreter it) {
  final m = <String, NativeFunction>{};

  String str(Object? self) => self is String ? self : jsToString(self);
  int intAt(List<Object?> a, int i, int def) {
    if (a.length <= i || a[i] == null) return def;
    final n = jsToNumber(a[i]);
    if (n.isNaN) return 0;
    return n.truncate();
  }

  NativeFunction reg(String name, Object? Function(String s, List<Object?> a) body) {
    return NativeFunction(name, (args, thisArg) => body(str(thisArg), args));
  }

  m['charAt'] = reg('charAt', (s, a) {
    final i = intAt(a, 0, 0);
    if (i < 0 || i >= s.length) return '';
    return s[i];
  });

  m['charCodeAt'] = reg('charCodeAt', (s, a) {
    final i = intAt(a, 0, 0);
    if (i < 0 || i >= s.length) return double.nan;
    return s.codeUnitAt(i);
  });

  m['codePointAt'] = reg('codePointAt', (s, a) {
    final i = intAt(a, 0, 0);
    if (i < 0 || i >= s.length) return null;
    return s.runes.elementAt(s.substring(0, i).runes.length);
  });

  m['at'] = reg('at', (s, a) {
    var i = intAt(a, 0, 0);
    if (i < 0) i += s.length;
    if (i < 0 || i >= s.length) return null;
    return s[i];
  });

  m['indexOf'] = reg('indexOf', (s, a) {
    final search = a.isEmpty ? 'undefined' : jsToString(a[0]);
    final from = intAt(a, 1, 0);
    return s.indexOf(search, from.clamp(0, s.length));
  });

  m['lastIndexOf'] = reg('lastIndexOf', (s, a) {
    final search = a.isEmpty ? 'undefined' : jsToString(a[0]);
    if (a.length < 2 || a[1] == null) return s.lastIndexOf(search);
    final from = intAt(a, 1, s.length);
    return s.lastIndexOf(search, from.clamp(0, s.length));
  });

  m['includes'] = reg('includes', (s, a) {
    final search = a.isEmpty ? 'undefined' : jsToString(a[0]);
    final from = intAt(a, 1, 0);
    if (from > s.length) return false;
    return s.indexOf(search, from.clamp(0, s.length)) >= 0;
  });

  m['startsWith'] = reg('startsWith', (s, a) {
    final search = a.isEmpty ? 'undefined' : jsToString(a[0]);
    final pos = intAt(a, 1, 0);
    if (pos < 0 || pos > s.length) return false;
    return s.startsWith(search, pos);
  });

  m['endsWith'] = reg('endsWith', (s, a) {
    final search = a.isEmpty ? 'undefined' : jsToString(a[0]);
    final end = a.length > 1 && a[1] != null ? intAt(a, 1, s.length) : s.length;
    final e = end.clamp(0, s.length);
    if (e - search.length < 0) return false;
    return s.substring(0, e).endsWith(search);
  });

  m['slice'] = reg('slice', (s, a) {
    int norm(int v) => v < 0 ? math.max(s.length + v, 0) : math.min(v, s.length);
    final start = norm(intAt(a, 0, 0));
    final end = a.length > 1 && a[1] != null ? norm(intAt(a, 1, s.length)) : s.length;
    if (start >= end) return '';
    return s.substring(start, end);
  });

  m['substring'] = reg('substring', (s, a) {
    final start = intAt(a, 0, 0).clamp(0, s.length);
    final end = a.length > 1 && a[1] != null ? intAt(a, 1, s.length).clamp(0, s.length) : s.length;
    final lo = math.min(start, end);
    final hi = math.max(start, end);
    return s.substring(lo, hi);
  });

  m['substr'] = reg('substr', (s, a) {
    var start = intAt(a, 0, 0);
    if (start < 0) start = math.max(s.length + start, 0);
    if (start >= s.length) return '';
    final len = a.length > 1 && a[1] != null ? intAt(a, 1, s.length - start) : s.length - start;
    if (len <= 0) return '';
    final end = math.min(start + len, s.length);
    return s.substring(start, end);
  });

  m['split'] = reg('split', (s, a) {
    final sep = a.isEmpty ? null : a[0];
    final limit = a.length > 1 && a[1] != null ? jsToNumber(a[1]).toInt() : -1;
    if (limit == 0) return <Object?>[];
    List<Object?> out;
    if (sep == null) {
      out = <Object?>[s];
    } else if (sep is JsRegExp) {
      out = _splitByRegExp(s, sep);
    } else {
      final pat = jsToString(sep);
      out = pat.isEmpty ? s.split('') : s.split(pat);
    }
    if (limit >= 0 && out.length > limit) out = out.sublist(0, limit);
    return out;
  });

  m['replace'] = reg('replace', (s, a) async {
    final pattern = a.isEmpty ? null : a[0];
    final replacement = a.length > 1 ? a[1] : '';
    return _replace(it, s, pattern, replacement, all: false);
  });

  m['replaceAll'] = reg('replaceAll', (s, a) async {
    final pattern = a.isEmpty ? null : a[0];
    final replacement = a.length > 1 ? a[1] : '';
    return _replace(it, s, pattern, replacement, all: true);
  });

  m['match'] = reg('match', (s, a) {
    final pattern = a.isEmpty ? null : a[0];
    final re = pattern is JsRegExp ? pattern : JsRegExp(jsToString(pattern), '');
    if (re.global) {
      final results = <Object?>[];
      for (final mm in re.regExp.allMatches(s)) {
        results.add(mm.group(0));
      }
      return results.isEmpty ? null : results;
    }
    final mm = re.regExp.firstMatch(s);
    if (mm == null) return null;
    return _matchToArray(mm, s);
  });

  m['matchAll'] = reg('matchAll', (s, a) {
    final pattern = a.isEmpty ? null : a[0];
    final re = pattern is JsRegExp ? pattern : JsRegExp(jsToString(pattern), 'g');
    final out = <Object?>[];
    for (final mm in re.regExp.allMatches(s)) {
      out.add(_matchToArray(mm, s));
    }
    return out;
  });

  m['search'] = reg('search', (s, a) {
    final pattern = a.isEmpty ? null : a[0];
    final re = pattern is JsRegExp ? pattern : JsRegExp(jsToString(pattern), '');
    final mm = re.regExp.firstMatch(s);
    return mm?.start ?? -1;
  });

  m['toLowerCase'] = reg('toLowerCase', (s, a) => s.toLowerCase());
  m['toUpperCase'] = reg('toUpperCase', (s, a) => s.toUpperCase());
  m['trim'] = reg('trim', (s, a) => s.trim());
  m['trimStart'] = reg('trimStart', (s, a) => s.trimLeft());
  m['trimEnd'] = reg('trimEnd', (s, a) => s.trimRight());
  m['trimLeft'] = reg('trimLeft', (s, a) => s.trimLeft());
  m['trimRight'] = reg('trimRight', (s, a) => s.trimRight());

  m['padStart'] = reg('padStart', (s, a) {
    final target = intAt(a, 0, 0);
    final pad = a.length > 1 ? jsToString(a[1]) : ' ';
    return _pad(s, target, pad, true);
  });

  m['padEnd'] = reg('padEnd', (s, a) {
    final target = intAt(a, 0, 0);
    final pad = a.length > 1 ? jsToString(a[1]) : ' ';
    return _pad(s, target, pad, false);
  });

  m['repeat'] = reg('repeat', (s, a) {
    final n = intAt(a, 0, 0);
    if (n < 0) it.fail('RangeError: repeat 次数不能为负');
    return s * n;
  });

  m['concat'] = reg('concat', (s, a) {
    final buf = StringBuffer(s);
    for (final x in a) {
      buf.write(jsToString(x));
    }
    return buf.toString();
  });

  m['localeCompare'] = reg('localeCompare', (s, a) {
    final other = a.isEmpty ? 'undefined' : jsToString(a[0]);
    return s.compareTo(other).sign;
  });

  m['toString'] = reg('toString', (s, a) => s);
  m['valueOf'] = reg('valueOf', (s, a) => s);

  m['normalize'] = reg('normalize', (s, a) => s);

  return m;
}

List<Object?> _splitByRegExp(String s, JsRegExp re) {
  final out = <Object?>[];
  var last = 0;
  for (final mm in re.regExp.allMatches(s)) {
    out.add(s.substring(last, mm.start));
    for (var i = 1; i <= mm.groupCount; i++) {
      out.add(mm.group(i));
    }
    last = mm.end;
  }
  out.add(s.substring(last));
  return out;
}

String _pad(String s, int target, String pad, bool start) {
  if (s.length >= target || pad.isEmpty) return s;
  final need = target - s.length;
  final buf = StringBuffer();
  while (buf.length < need) {
    buf.write(pad);
  }
  final padding = buf.toString().substring(0, need);
  return start ? padding + s : s + padding;
}

Future<String> _replace(
  Interpreter it,
  String s,
  Object? pattern,
  Object? replacement, {
  required bool all,
}) async {
  final bool replaceAll = all || (pattern is JsRegExp && pattern.global);
  final buf = StringBuffer();
  var last = 0;
  var replaced = false;

  if (pattern is JsRegExp) {
    for (final mm in pattern.regExp.allMatches(s)) {
      buf.write(s.substring(last, mm.start));
      buf.write(await _replacementText(it, replacement, mm, s));
      last = mm.end;
      replaced = true;
      if (!replaceAll) break;
    }
  } else {
    final needle = pattern == null ? 'undefined' : jsToString(pattern);
    if (needle.isEmpty) {
      // 空串替换：每个字符之间插入
      if (!all) {
        return await _plainReplacement(it, replacement, '', 0, s) + s;
      }
      final b = StringBuffer();
      b.write(await _plainReplacement(it, replacement, '', 0, s));
      for (var i = 0; i < s.length; i++) {
        b.write(s[i]);
        b.write(await _plainReplacement(it, replacement, '', i + 1, s));
      }
      return b.toString();
    }
    var from = 0;
    while (true) {
      final idx = s.indexOf(needle, from);
      if (idx < 0) break;
      buf.write(s.substring(last, idx));
      buf.write(await _plainReplacement(it, replacement, needle, idx, s));
      last = idx + needle.length;
      from = last;
      replaced = true;
      if (!replaceAll) break;
    }
  }
  if (!replaced) return s;
  buf.write(s.substring(last));
  return buf.toString();
}

Future<String> _plainReplacement(
  Interpreter it,
  Object? replacement,
  String matched,
  int offset,
  String source,
) async {
  if (replacement is JsCallable || replacement is Function) {
    final r = await it.callFunction(replacement, <Object?>[matched, offset, source]);
    return jsToString(r);
  }
  return _expandReplacement(jsToString(replacement), null, matched, offset, source);
}

Future<String> _replacementText(
  Interpreter it,
  Object? replacement,
  RegExpMatch m,
  String source,
) async {
  final matched = m.group(0) ?? '';
  if (replacement is JsCallable || replacement is Function) {
    final args = <Object?>[matched];
    for (var i = 1; i <= m.groupCount; i++) {
      args.add(m.group(i));
    }
    args.add(m.start);
    args.add(source);
    final r = await it.callFunction(replacement, args);
    return jsToString(r);
  }
  return _expandReplacement(jsToString(replacement), m, matched, m.start, source);
}

String _expandReplacement(String repl, RegExpMatch? m, String matched, int offset, String source) {
  final buf = StringBuffer();
  var i = 0;
  while (i < repl.length) {
    final c = repl[i];
    if (c != r'$' || i == repl.length - 1) {
      buf.write(c);
      i++;
      continue;
    }
    final n = repl[i + 1];
    if (n == r'$') {
      buf.write(r'$');
      i += 2;
    } else if (n == '&') {
      buf.write(matched);
      i += 2;
    } else if (n == '`') {
      buf.write(source.substring(0, offset));
      i += 2;
    } else if (n == "'") {
      buf.write(source.substring(offset + matched.length));
      i += 2;
    } else if (n == '<') {
      final close = repl.indexOf('>', i + 2);
      if (close < 0) {
        buf.write(r'$');
        i++;
        continue;
      }
      final name = repl.substring(i + 2, close);
      buf.write(m?.namedGroup(name) ?? '');
      i = close + 1;
    } else if (n.codeUnitAt(0) >= 0x30 && n.codeUnitAt(0) <= 0x39) {
      var digits = n;
      var len = 2;
      if (i + 2 < repl.length) {
        final n2 = repl[i + 2];
        if (n2.codeUnitAt(0) >= 0x30 && n2.codeUnitAt(0) <= 0x39) {
          digits = '$n$n2';
          len = 3;
        }
      }
      final idx = int.tryParse(digits);
      if (idx != null && m != null && idx <= m.groupCount) {
        buf.write(m.group(idx) ?? '');
      } else {
        buf.write('\$$digits');
      }
      i += len;
    } else {
      buf.write(r'$');
      i++;
    }
  }
  return buf.toString();
}

// ===========================================================================
// Array 实例方法
// ===========================================================================

Map<String, NativeFunction> createArrayMethods(Interpreter it) {
  final m = <String, NativeFunction>{};

  List<Object?> arr(Object? self) {
    if (self is List) return self;
    it.fail('TypeError: 数组方法被用在了非数组上');
  }

  NativeFunction reg(String name, Object? Function(List<Object?> a, List<Object?> self) body) {
    return NativeFunction(name, (args, thisArg) => body(args, arr(thisArg)));
  }

  m['push'] = reg('push', (a, self) {
    self.addAll(a);
    return self.length;
  });

  m['pop'] = reg('pop', (a, self) => self.isEmpty ? null : self.removeLast());

  m['shift'] = reg('shift', (a, self) => self.isEmpty ? null : self.removeAt(0));

  m['unshift'] = reg('unshift', (a, self) {
    self.insertAll(0, a);
    return self.length;
  });

  m['slice'] = reg('slice', (a, self) {
    int norm(int v) => v < 0 ? math.max(self.length + v, 0) : math.min(v, self.length);
    final start = a.isNotEmpty && a[0] != null ? norm(jsToNumber(a[0]).toInt()) : 0;
    final end = a.length > 1 && a[1] != null ? norm(jsToNumber(a[1]).toInt()) : self.length;
    if (start >= end) return <Object?>[];
    return self.sublist(start, end);
  });

  m['splice'] = reg('splice', (a, self) {
    int start;
    if (a.isEmpty || a[0] == null) {
      start = 0;
    } else {
      final v = jsToNumber(a[0]).toInt();
      start = v < 0 ? math.max(self.length + v, 0) : math.min(v, self.length);
    }
    final deleteCount = a.length > 1 ? jsToNumber(a[1]).toInt().clamp(0, self.length - start) : self.length - start;
    final removed = self.sublist(start, start + deleteCount);
    final items = a.length > 2 ? a.sublist(2) : const <Object?>[];
    self.removeRange(start, start + deleteCount);
    self.insertAll(start, items);
    return removed;
  });

  m['concat'] = reg('concat', (a, self) {
    final out = <Object?>[...self];
    for (final x in a) {
      if (x is List) {
        out.addAll(x);
      } else {
        out.add(x);
      }
    }
    return out;
  });

  m['join'] = reg('join', (a, self) {
    final sep = a.isEmpty || a[0] == null ? ',' : jsToString(a[0]);
    return self.map((e) => e == null ? '' : jsToString(e)).join(sep);
  });

  m['indexOf'] = reg('indexOf', (a, self) {
    final target = a.isEmpty ? null : a[0];
    final from = a.length > 1 && a[1] != null ? jsToNumber(a[1]).toInt() : 0;
    for (var i = math.max(from, 0); i < self.length; i++) {
      if (jsStrictEquals(self[i], target)) return i;
    }
    return -1;
  });

  m['lastIndexOf'] = reg('lastIndexOf', (a, self) {
    final target = a.isEmpty ? null : a[0];
    var from = a.length > 1 && a[1] != null ? jsToNumber(a[1]).toInt() : self.length - 1;
    if (from >= self.length) from = self.length - 1;
    for (var i = from; i >= 0; i--) {
      if (jsStrictEquals(self[i], target)) return i;
    }
    return -1;
  });

  m['includes'] = reg('includes', (a, self) {
    final target = a.isEmpty ? null : a[0];
    return self.any((e) => jsStrictEquals(e, target) || (e is num && target is num && e.isNaN && target.isNaN));
  });

  m['reverse'] = reg('reverse', (a, self) {
    final copy = self.reversed.toList();
    for (var i = 0; i < copy.length; i++) {
      self[i] = copy[i];
    }
    return self;
  });

  m['sort'] = reg('sort', (a, self) async {
    final cmp = a.isEmpty ? null : a[0];
    final sorted = await _mergeSort(self, (x, y) async {
      if (cmp == null) {
        final xs = jsToString(x);
        final ys = jsToString(y);
        return xs.compareTo(ys);
      }
      final r = jsToNumber(await it.callFunction(cmp, <Object?>[x, y]));
      if (r.isNaN) return 0;
      return r.sign.toInt();
    });
    for (var i = 0; i < sorted.length; i++) {
      self[i] = sorted[i];
    }
    return self;
  });

  m['map'] = reg('map', (a, self) async {
    final fn = a.isEmpty ? null : a[0];
    final thisArg = a.length > 1 ? a[1] : null;
    final out = <Object?>[];
    for (var i = 0; i < self.length; i++) {
      out.add(await it.callFunction(
        fn,
        <Object?>[self[i], i, self],
        thisArg: thisArg,
      ));
    }
    return out;
  });

  m['filter'] = reg('filter', (a, self) async {
    final fn = a.isEmpty ? null : a[0];
    final thisArg = a.length > 1 ? a[1] : null;
    final out = <Object?>[];
    for (var i = 0; i < self.length; i++) {
      final r = await it.callFunction(
        fn,
        <Object?>[self[i], i, self],
        thisArg: thisArg,
      );
      if (jsToBoolean(r)) out.add(self[i]);
    }
    return out;
  });

  m['forEach'] = reg('forEach', (a, self) async {
    final fn = a.isEmpty ? null : a[0];
    final thisArg = a.length > 1 ? a[1] : null;
    for (var i = 0; i < self.length; i++) {
      await it.callFunction(
        fn,
        <Object?>[self[i], i, self],
        thisArg: thisArg,
      );
    }
    return null;
  });

  m['reduce'] = reg('reduce', (a, self) async {
    final fn = a.isEmpty ? null : a[0];
    var i = 0;
    Object? acc;
    if (a.length > 1) {
      acc = a[1];
    } else {
      if (self.isEmpty) it.fail('TypeError: 空数组没有初始值时不能 reduce');
      acc = self[0];
      i = 1;
    }
    for (; i < self.length; i++) {
      acc = await it.callFunction(fn, <Object?>[acc, self[i], i, self]);
    }
    return acc;
  });

  m['reduceRight'] = reg('reduceRight', (a, self) async {
    final fn = a.isEmpty ? null : a[0];
    var i = self.length - 1;
    Object? acc;
    if (a.length > 1) {
      acc = a[1];
    } else {
      if (self.isEmpty) it.fail('TypeError: 空数组没有初始值时不能 reduceRight');
      acc = self[i];
      i--;
    }
    for (; i >= 0; i--) {
      acc = await it.callFunction(fn, <Object?>[acc, self[i], i, self]);
    }
    return acc;
  });

  m['find'] = reg('find', (a, self) async {
    final fn = a.isEmpty ? null : a[0];
    for (var i = 0; i < self.length; i++) {
      final r = await it.callFunction(fn, <Object?>[self[i], i, self]);
      if (jsToBoolean(r)) return self[i];
    }
    return null;
  });

  m['findIndex'] = reg('findIndex', (a, self) async {
    final fn = a.isEmpty ? null : a[0];
    for (var i = 0; i < self.length; i++) {
      final r = await it.callFunction(fn, <Object?>[self[i], i, self]);
      if (jsToBoolean(r)) return i;
    }
    return -1;
  });

  m['some'] = reg('some', (a, self) async {
    final fn = a.isEmpty ? null : a[0];
    for (var i = 0; i < self.length; i++) {
      final r = await it.callFunction(fn, <Object?>[self[i], i, self]);
      if (jsToBoolean(r)) return true;
    }
    return false;
  });

  m['every'] = reg('every', (a, self) async {
    final fn = a.isEmpty ? null : a[0];
    for (var i = 0; i < self.length; i++) {
      final r = await it.callFunction(fn, <Object?>[self[i], i, self]);
      if (!jsToBoolean(r)) return false;
    }
    return true;
  });

  m['flat'] = reg('flat', (a, self) {
    final depth = a.isEmpty || a[0] == null ? 1 : jsToNumber(a[0]).toInt();
    return _flatten(self, depth);
  });

  m['flatMap'] = reg('flatMap', (a, self) async {
    final fn = a.isEmpty ? null : a[0];
    final out = <Object?>[];
    for (var i = 0; i < self.length; i++) {
      final v = await it.callFunction(fn, <Object?>[self[i], i, self]);
      if (v is List) {
        out.addAll(v);
      } else {
        out.add(v);
      }
    }
    return out;
  });

  m['fill'] = reg('fill', (a, self) {
    final value = a.isEmpty ? null : a[0];
    var start = a.length > 1 && a[1] != null ? jsToNumber(a[1]).toInt() : 0;
    var end = a.length > 2 && a[2] != null ? jsToNumber(a[2]).toInt() : self.length;
    if (start < 0) start += self.length;
    if (end < 0) end += self.length;
    start = start.clamp(0, self.length);
    end = end.clamp(0, self.length);
    for (var i = start; i < end; i++) {
      self[i] = value;
    }
    return self;
  });

  m['keys'] = reg('keys', (a, self) => List<Object?>.generate(self.length, (i) => i));
  m['values'] = reg('values', (a, self) => List<Object?>.from(self));
  m['entries'] = reg('entries', (a, self) {
    return <Object?>[
      for (var i = 0; i < self.length; i++) <Object?>[i, self[i]],
    ];
  });

  m['at'] = reg('at', (a, self) {
    var i = a.isEmpty ? 0 : jsToNumber(a[0]).toInt();
    if (i < 0) i += self.length;
    if (i < 0 || i >= self.length) return null;
    return self[i];
  });

  m['toString'] = reg('toString', (a, self) => self.map((e) => e == null ? '' : jsToString(e)).join(','));
  m['valueOf'] = reg('valueOf', (a, self) => self);

  return m;
}

List<Object?> _flatten(List<Object?> list, int depth) {
  final out = <Object?>[];
  for (final v in list) {
    if (v is List && depth > 0) {
      out.addAll(_flatten(v, depth - 1));
    } else {
      out.add(v);
    }
  }
  return out;
}

Future<List<Object?>> _mergeSort(
  List<Object?> list,
  Future<int> Function(Object?, Object?) cmp,
) async {
  if (list.length <= 1) return List<Object?>.from(list);
  final mid = list.length ~/ 2;
  final left = await _mergeSort(list.sublist(0, mid), cmp);
  final right = await _mergeSort(list.sublist(mid), cmp);
  final out = <Object?>[];
  var i = 0, j = 0;
  while (i < left.length && j < right.length) {
    if (await cmp(left[i], right[j]) <= 0) {
      out.add(left[i++]);
    } else {
      out.add(right[j++]);
    }
  }
  while (i < left.length) {
    out.add(left[i++]);
  }
  while (j < right.length) {
    out.add(right[j++]);
  }
  return out;
}

// ===========================================================================
// 全局对象
// ===========================================================================

void installGlobals(Interpreter it, Scope global) {
  global.define('undefined', null);
  global.define('NaN', double.nan);
  global.define('Infinity', double.infinity);

  global.define('Math', _mathObject());
  global.define('JSON', _jsonObject(it));
  global.define('Object', _objectConstructor(it));
  global.define('Array', _arrayConstructor(it));
  global.define('String', _stringConstructor(it));
  global.define('Number', _numberConstructor());
  global.define('Boolean', NativeFunction('Boolean', (a, _) => jsToBoolean(a.isEmpty ? null : a[0])));
  global.define('Date', _dateConstructor());
  global.define('RegExp', _regexpConstructor());
  global.define('Error', _errorConstructor());
  global.define('TypeError', _errorConstructor());
  global.define('console', _consoleObject(it));

  global.define('parseInt', NativeFunction('parseInt', (a, _) {
    final s = a.isEmpty ? 'undefined' : jsToString(a[0]);
    final radix = a.length > 1 && a[1] != null ? jsToNumber(a[1]).toInt() : null;
    return _parseInt(s, radix);
  }));

  global.define('parseFloat', NativeFunction('parseFloat', (a, _) {
    final s = a.isEmpty ? 'undefined' : jsToString(a[0]);
    return _parseFloat(s);
  }));

  global.define('isNaN', NativeFunction('isNaN', (a, _) => jsToNumber(a.isEmpty ? null : a[0]).isNaN));

  global.define('isFinite', NativeFunction('isFinite', (a, _) {
    final n = jsToNumber(a.isEmpty ? null : a[0]);
    return n.isFinite;
  }));

  global.define('encodeURIComponent', NativeFunction('encodeURIComponent', (a, _) {
    return _encodeUriComponent(a.isEmpty ? 'undefined' : jsToString(a[0]));
  }));

  global.define('decodeURIComponent', NativeFunction('decodeURIComponent', (a, _) {
    final s = a.isEmpty ? 'undefined' : jsToString(a[0]);
    try {
      return Uri.decodeComponent(s);
    } on ArgumentError {
      it.fail('URIError: 非法的 URI 编码 "$s"');
    } on FormatException {
      it.fail('URIError: 非法的 URI 编码 "$s"');
    }
  }));

  global.define('encodeURI', NativeFunction('encodeURI', (a, _) {
    return _encodeUri(a.isEmpty ? 'undefined' : jsToString(a[0]));
  }));

  global.define('decodeURI', NativeFunction('decodeURI', (a, _) {
    final s = a.isEmpty ? 'undefined' : jsToString(a[0]);
    try {
      return Uri.decodeFull(s);
    } on ArgumentError {
      it.fail('URIError: 非法的 URI 编码 "$s"');
    }
  }));

  global.define('escape', NativeFunction('escape', (a, _) {
    return _escape(a.isEmpty ? 'undefined' : jsToString(a[0]));
  }));

  global.define('unescape', NativeFunction('unescape', (a, _) {
    return _unescape(a.isEmpty ? 'undefined' : jsToString(a[0]));
  }));

  global.define('btoa', NativeFunction('btoa', (a, _) {
    final s = a.isEmpty ? 'undefined' : jsToString(a[0]);
    return base64Encode(latin1.encode(s));
  }));

  global.define('atob', NativeFunction('atob', (a, _) {
    final s = a.isEmpty ? 'undefined' : jsToString(a[0]);
    try {
      return latin1.decode(base64Decode(s));
    } on FormatException {
      it.fail('InvalidCharacterError: atob 收到非法 base64');
    }
  }));

  global.define('print', NativeFunction('print', (a, _) {
    it.log(a.map(jsToString).join(' '));
    return null;
  }));
}

JsHostObject _consoleObject(Interpreter it) {
  return JsHostObject(label: 'console', methods: {
    'log': (a) {
      it.log(a.map(jsToString).join(' '));
      return null;
    },
    'info': (a) {
      it.log(a.map(jsToString).join(' '));
      return null;
    },
    'warn': (a) {
      it.log('[warn] ${a.map(jsToString).join(' ')}');
      return null;
    },
    'error': (a) {
      it.log('[error] ${a.map(jsToString).join(' ')}');
      return null;
    },
    'debug': (a) {
      it.log(a.map(jsToString).join(' '));
      return null;
    },
  });
}

JsHostObject _mathObject() {
  return JsHostObject(label: 'Math', methods: {
    'floor': (a) => jsToNumber(a.isEmpty ? null : a[0]).floor(),
    'ceil': (a) => jsToNumber(a.isEmpty ? null : a[0]).ceil(),
    'round': (a) => _jsRound(jsToNumber(a.isEmpty ? null : a[0])),
    'abs': (a) => jsToNumber(a.isEmpty ? null : a[0]).abs(),
    'trunc': (a) => jsToNumber(a.isEmpty ? null : a[0]).truncate(),
    'sign': (a) {
      final n = jsToNumber(a.isEmpty ? null : a[0]);
      if (n.isNaN) return double.nan;
      return n.sign.toInt();
    },
    'sqrt': (a) => math.sqrt(jsToNumber(a.isEmpty ? null : a[0])),
    'cbrt': (a) {
      final n = jsToNumber(a.isEmpty ? null : a[0]);
      return n.sign * math.pow(n.abs(), 1 / 3);
    },
    'pow': (a) => math.pow(jsToNumber(a.isEmpty ? null : a[0]), jsToNumber(a.length > 1 ? a[1] : null)),
    'log': (a) => math.log(jsToNumber(a.isEmpty ? null : a[0])),
    'log2': (a) => math.log(jsToNumber(a.isEmpty ? null : a[0])) / math.ln2,
    'log10': (a) => math.log(jsToNumber(a.isEmpty ? null : a[0])) / math.ln10,
    'exp': (a) => math.exp(jsToNumber(a.isEmpty ? null : a[0])),
    'sin': (a) => math.sin(jsToNumber(a.isEmpty ? null : a[0])),
    'cos': (a) => math.cos(jsToNumber(a.isEmpty ? null : a[0])),
    'tan': (a) => math.tan(jsToNumber(a.isEmpty ? null : a[0])),
    'asin': (a) => math.asin(jsToNumber(a.isEmpty ? null : a[0])),
    'acos': (a) => math.acos(jsToNumber(a.isEmpty ? null : a[0])),
    'atan': (a) => math.atan(jsToNumber(a.isEmpty ? null : a[0])),
    'atan2': (a) => math.atan2(jsToNumber(a.isEmpty ? null : a[0]), jsToNumber(a.length > 1 ? a[1] : null)),
    'min': (a) {
      var m = double.infinity;
      for (final v in a) {
        final n = jsToNumber(v);
        if (n.isNaN) return double.nan;
        if (n < m) m = n.toDouble();
      }
      return _numResult(m);
    },
    'max': (a) {
      var m = double.negativeInfinity;
      for (final v in a) {
        final n = jsToNumber(v);
        if (n.isNaN) return double.nan;
        if (n > m) m = n.toDouble();
      }
      return _numResult(m);
    },
    'random': (a) => math.Random().nextDouble(),
    'hypot': (a) {
      var sum = 0.0;
      for (final v in a) {
        final n = jsToNumber(v).toDouble();
        sum += n * n;
      }
      return math.sqrt(sum);
    },
  }, props: {
    'PI': math.pi,
    'E': math.e,
    'LN2': math.ln2,
    'LN10': math.ln10,
    'SQRT2': math.sqrt2,
  });
}

num _numResult(num n) {
  if (n is double && n.isFinite && n == n.truncateToDouble()) return n.toInt();
  return n;
}

num _jsRound(num n) {
  if (n.isNaN || n.isInfinite) return n;
  // JS Math.round 对 .5 向 +∞ 取整
  final r = (n + 0.5).floor();
  return r;
}

JsHostObject _jsonObject(Interpreter it) {
  return JsHostObject(label: 'JSON', methods: {
    'parse': (a) {
      final text = a.isEmpty ? 'undefined' : jsToString(a[0]);
      try {
        return jsonDecode(text);
      } on FormatException catch (e) {
        it.fail('SyntaxError: JSON.parse 失败: ${e.message}');
      }
    },
    'stringify': (a) {
      final value = a.isEmpty ? null : a[0];
      final space = a.length > 2 && a[2] != null ? a[2] : null;
      final indent = space is String ? space : (space is num ? ' ' * space.toInt().clamp(0, 10) : '');
      final out = _jsonStringify(value, indent, 0);
      return out;
    },
  });
}

String? _jsonStringify(Object? v, String indent, int depth) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) {
    if (!v.isFinite) return 'null';
    return numToJsString(v);
  }
  if (v is String) return jsonEncode(v);
  if (v is JsDate) return v.isValid ? jsonEncode(v.toISOString()) : 'null';
  if (v is JsRegExp) return '{}';
  if (v is JsCallable || v is Function) return null;
  if (v is JsHostObject) {
    final map = <String, Object?>{};
    for (final k in v.ownKeys()) {
      map[k] = v.getProperty(k);
    }
    return _jsonStringify(map, indent, depth);
  }
  if (v is List) {
    final items = <String>[];
    for (final e in v) {
      final s = _jsonStringify(e, indent, depth + 1);
      items.add(s ?? 'null');
    }
    if (items.isEmpty) return '[]';
    if (indent.isEmpty) return '[${items.join(',')}]';
    final pad = indent * (depth + 1);
    return '[\n$pad${items.join(',\n$pad')}\n${indent * depth}]';
  }
  if (v is Map) {
    final items = <String>[];
    v.forEach((k, val) {
      final s = _jsonStringify(val, indent, depth + 1);
      if (s == null) return;
      items.add(indent.isEmpty ? '${jsonEncode(k)}:$s' : '${jsonEncode(k)}: $s');
    });
    if (items.isEmpty) return '{}';
    if (indent.isEmpty) return '{${items.join(',')}}';
    final pad = indent * (depth + 1);
    return '{\n$pad${items.join(',\n$pad')}\n${indent * depth}}';
  }
  return null;
}

JsHostObject _objectConstructor(Interpreter it) {
  return JsHostObject(
    label: 'Object',
    callFn: (a, _) {
      if (a.isEmpty || a[0] == null) return <String, Object?>{};
      final v = a[0];
      if (v is Map || v is List || v is JsHostObject) return v;
      return <String, Object?>{};
    },
    constructFn: (a) {
      if (a.isEmpty || a[0] == null) return <String, Object?>{};
      return a[0];
    },
    methods: {
      'keys': (a) => _objectKeys(a.isEmpty ? null : a[0]),
      'values': (a) => _objectValues(a.isEmpty ? null : a[0]),
      'entries': (a) => _objectEntries(a.isEmpty ? null : a[0]),
      'assign': (a) {
        if (a.isEmpty) return <String, Object?>{};
        final target = a[0];
        if (target is Map) {
          for (final src in a.skip(1)) {
            if (src is Map) target.addAll(src);
          }
          return target;
        }
        return target;
      },
      'fromEntries': (a) {
        final out = <String, Object?>{};
        final list = a.isEmpty ? null : a[0];
        if (list is List) {
          for (final e in list) {
            if (e is List && e.length >= 2) {
              out[jsToString(e[0])] = e[1];
            }
          }
        } else if (list is Map) {
          list.forEach((k, v) => out[k] = v);
        }
        return out;
      },
      'freeze': (a) => a.isEmpty ? null : a[0],
    },
  );
}

List<Object?> _objectKeys(Object? obj) {
  if (obj == null) return <Object?>[];
  if (obj is Map) return obj.keys.toList();
  if (obj is List) return List<Object?>.generate(obj.length, (i) => '$i');
  if (obj is String) return List<Object?>.generate(obj.length, (i) => '$i');
  if (obj is JsHostObject) return obj.ownKeys();
  return <Object?>[];
}

List<Object?> _objectValues(Object? obj) {
  if (obj == null) return <Object?>[];
  if (obj is Map) return obj.values.toList();
  if (obj is List) return List<Object?>.from(obj);
  if (obj is String) return obj.split('');
  if (obj is JsHostObject) return [for (final k in obj.ownKeys()) obj.getProperty(k)];
  return <Object?>[];
}

List<Object?> _objectEntries(Object? obj) {
  if (obj == null) return <Object?>[];
  if (obj is Map) return [for (final e in obj.entries) <Object?>[e.key, e.value]];
  if (obj is List) return List<Object?>.generate(obj.length, (i) => <Object?>['$i', obj[i]]);
  if (obj is String) return List<Object?>.generate(obj.length, (i) => <Object?>['$i', obj[i]]);
  if (obj is JsHostObject) return [for (final k in obj.ownKeys()) <Object?>[k, obj.getProperty(k)]];
  return <Object?>[];
}

JsHostObject _arrayConstructor(Interpreter it) {
  Object? create(List<Object?> a) {
    if (a.length == 1 && a[0] is num) {
      final n = jsToNumber(a[0]).toInt();
      if (n < 0) it.fail('RangeError: 数组长度不能为负');
      return List<Object?>.filled(n, null);
    }
    return List<Object?>.from(a);
  }

  return JsHostObject(
    label: 'Array',
    callFn: (a, _) => create(a),
    constructFn: create,
    methods: {
      'isArray': (a) => a.isNotEmpty && a[0] is List,
      'from': (a) {
        final src = a.isEmpty ? null : a[0];
        if (src is List) return List<Object?>.from(src);
        if (src is String) return src.split('');
        if (src is Map) return src.values.toList();
        return <Object?>[];
      },
      'of': (a) => List<Object?>.from(a),
    },
  );
}

JsHostObject _stringConstructor(Interpreter it) {
  return JsHostObject(
    label: 'String',
    callFn: (a, _) => a.isEmpty ? '' : jsToString(a[0]),
    constructFn: (a) => a.isEmpty ? '' : jsToString(a[0]),
    methods: {
      'fromCharCode': (a) => String.fromCharCodes(a.map((e) => jsToNumber(e).toInt())),
      'fromCodePoint': (a) => a.map((e) => String.fromCharCode(jsToNumber(e).toInt())).join(),
    },
    props: {
      'fromCharCode': NativeFunction('fromCharCode', (a, _) => String.fromCharCodes(a.map((e) => jsToNumber(e).toInt()))),
      'fromCodePoint': NativeFunction('fromCodePoint', (a, _) => a.map((e) => String.fromCharCode(jsToNumber(e).toInt())).join()),
    },
  );
}

JsHostObject _numberConstructor() {
  Object? convert(List<Object?> a) => a.isEmpty ? 0 : jsToNumber(a[0]);

  return JsHostObject(
    label: 'Number',
    callFn: (a, _) => convert(a),
    constructFn: convert,
    methods: {
      'isNaN': (a) => a.isNotEmpty && a[0] is num && (a[0] as num).isNaN,
      'isFinite': (a) => a.isNotEmpty && a[0] is num && (a[0] as num).isFinite,
      'isInteger': (a) => a.isNotEmpty && a[0] is num && (a[0] as num) == (a[0] as num).truncateToDouble(),
      'parseInt': (a) {
        final s = a.isEmpty ? 'undefined' : jsToString(a[0]);
        final radix = a.length > 1 && a[1] != null ? jsToNumber(a[1]).toInt() : null;
        return _parseInt(s, radix);
      },
      'parseFloat': (a) => _parseFloat(a.isEmpty ? 'undefined' : jsToString(a[0])),
    },
    props: {
      'MAX_SAFE_INTEGER': 9007199254740991,
      'MIN_SAFE_INTEGER': -9007199254740991,
      'EPSILON': 2.220446049250313e-16,
      'isNaN': NativeFunction('isNaN', (a, _) => a.isNotEmpty && a[0] is num && (a[0] as num).isNaN),
    },
  );
}

JsHostObject _dateConstructor() {
  Object? create(List<Object?> a) {
    if (a.isEmpty) return JsDate.now();
    final v = a[0];
    if (v is num) return JsDate(v);
    if (v is String) {
      final dt = DateTime.tryParse(v);
      if (dt == null) return JsDate(double.nan);
      return JsDate.fromDateTime(dt);
    }
    if (v is JsDate) return JsDate(v.millisecondsSinceEpoch);
    return JsDate.now();
  }

  return JsHostObject(
    label: 'Date',
    callFn: (a, _) => create(a).toString(),
    constructFn: create,
    methods: {
      'now': (a) => DateTime.now().millisecondsSinceEpoch,
      'parse': (a) {
        final s = a.isEmpty ? 'undefined' : jsToString(a[0]);
        final dt = DateTime.tryParse(s);
        return dt?.millisecondsSinceEpoch ?? double.nan;
      },
    },
    props: {
      'now': NativeFunction('now', (a, _) => DateTime.now().millisecondsSinceEpoch),
      'parse': NativeFunction('parse', (a, _) {
        final s = a.isEmpty ? 'undefined' : jsToString(a[0]);
        return DateTime.tryParse(s)?.millisecondsSinceEpoch ?? double.nan;
      }),
    },
  );
}

JsHostObject _regexpConstructor() {
  Object? create(List<Object?> a) {
    final pattern = a.isEmpty ? null : a[0];
    if (pattern is JsRegExp) return pattern;
    final flags = a.length > 1 && a[1] != null ? jsToString(a[1]) : '';
    return JsRegExp(pattern == null ? '' : jsToString(pattern), flags);
  }

  return JsHostObject(
    label: 'RegExp',
    callFn: (a, _) => create(a),
    constructFn: create,
  );
}

JsHostObject _errorConstructor() {
  Object? create(List<Object?> a) {
    final msg = a.isEmpty ? '' : jsToString(a[0]);
    return <String, Object?>{'name': 'Error', 'message': msg, 'stack': msg};
  }

  return JsHostObject(label: 'Error', callFn: (a, _) => create(a), constructFn: create);
}

// ===========================================================================
// 编码/解析小工具
// ===========================================================================

num _parseInt(String s, int? radix) {
  final str = s.trim();
  var sign = 1;
  var i = 0;
  if (str.isNotEmpty && (str[0] == '+' || str[0] == '-')) {
    if (str[0] == '-') sign = -1;
    i = 1;
  }
  var r = radix ?? 0;
  if (r == 0) {
    if (i + 1 < str.length && str[i] == '0' && (str[i + 1] == 'x' || str[i + 1] == 'X')) {
      r = 16;
      i += 2;
    } else {
      r = 10;
    }
  } else if (r == 16 && i + 1 < str.length && str[i] == '0' && (str[i + 1] == 'x' || str[i + 1] == 'X')) {
    i += 2;
  }
  if (r < 2 || r > 36) return double.nan;
  var value = 0;
  var any = false;
  for (; i < str.length; i++) {
    final d = int.tryParse(str[i], radix: r);
    if (d == null) break;
    value = value * r + d;
    any = true;
  }
  if (!any) return double.nan;
  return sign * value;
}

num _parseFloat(String s) {
  final t = s.trim();
  if (t.isEmpty) return double.nan;
  if (t.startsWith('Infinity') || t.startsWith('+Infinity')) return double.infinity;
  if (t.startsWith('-Infinity')) return double.negativeInfinity;
  final re = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?');
  final m = re.firstMatch(t);
  if (m == null) return double.nan;
  return double.parse(m.group(0)!);
}

const String _unreserved =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*\'()';

String _encodeUriComponent(String s) {
  final buf = StringBuffer();
  for (final byte in utf8.encode(s)) {
    final ch = String.fromCharCode(byte);
    if (byte < 128 && _unreserved.contains(ch)) {
      buf.write(ch);
    } else {
      buf.write('%');
      buf.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buf.toString();
}

String _encodeUri(String s) {
  const reserved = ';,/?:@&=+\$#';
  final buf = StringBuffer();
  for (final byte in utf8.encode(s)) {
    final ch = String.fromCharCode(byte);
    if (byte < 128 && (_unreserved.contains(ch) || reserved.contains(ch))) {
      buf.write(ch);
    } else {
      buf.write('%');
      buf.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buf.toString();
}

String _escape(String s) {
  const safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@*_+-./";
  final buf = StringBuffer();
  for (final cu in s.codeUnits) {
    final ch = String.fromCharCode(cu);
    if (cu < 128 && safe.contains(ch)) {
      buf.write(ch);
    } else if (cu < 256) {
      buf.write('%');
      buf.write(cu.toRadixString(16).toUpperCase().padLeft(2, '0'));
    } else {
      buf.write('%u');
      buf.write(cu.toRadixString(16).toUpperCase().padLeft(4, '0'));
    }
  }
  return buf.toString();
}

String _unescape(String s) {
  final buf = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '%') {
      if (i + 5 < s.length && s[i + 1] == 'u') {
        final code = int.tryParse(s.substring(i + 2, i + 6), radix: 16);
        if (code != null) {
          buf.writeCharCode(code);
          i += 6;
          continue;
        }
      }
      if (i + 2 < s.length) {
        final code = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
        if (code != null) {
          buf.writeCharCode(code);
          i += 3;
          continue;
        }
      }
    }
    buf.write(c);
    i++;
  }
  return buf.toString();
}

// ignore: unused_element
Uint8List _bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
