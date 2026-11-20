import 'dart:convert';

import '../../domain/domain.dart';
import '../../kernel/errors.dart';
import '../../store/database.dart';
import '../../store/dao/replace_rule_dao.dart';
import '../../store/store.dart';

/// 一条替换规则组，对应契约 `ReplaceRuleView`。
///
/// `replace_rules` 表一行只装一条正则（Kotlin 原版结构），而契约的 `raw`
/// 是规则**数组**文本。映射约定：同 `name + group` 的若干行属于同一组，
/// 组的 `id` 取组内首行 id；`raw` 是这些行的 JSON 数组。
/// 这样既能满足 UI 的「一组一次编辑」，又不破坏 DAO 按行做正文净化的查询。
class ReplaceRuleView {
  const ReplaceRuleView({
    required this.id,
    required this.name,
    required this.group,
    required this.enabled,
    required this.order,
    required this.raw,
  });

  final int id;
  final String name;
  final String group;
  final bool enabled;
  final int order;
  final String raw;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'group': group,
        'enabled': enabled,
        'order': order,
        'raw': raw,
      };
}

/// 导入失败项，对应契约 `{name, reason}`。
class ReplaceRuleFailure {
  const ReplaceRuleFailure({required this.name, required this.reason});

  final String name;
  final String reason;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'reason': reason,
      };
}

/// 导入结果，对应契约 `ReplaceRuleImportResult`。
class ReplaceRuleImportResult {
  const ReplaceRuleImportResult({
    this.imported = 0,
    this.updated = 0,
    this.skipped = 0,
    this.rules = const [],
    this.failures = const [],
  });

  final int imported;
  final int updated;
  final int skipped;
  final List<ReplaceRuleView> rules;
  final List<ReplaceRuleFailure> failures;

  Map<String, Object?> toJson() => <String, Object?>{
        'imported': imported,
        'updated': updated,
        'skipped': skipped,
        'rules': [for (final rule in rules) rule.toJson()],
        'failures': [for (final failure in failures) failure.toJson()],
      };
}

/// 替换规则域。
class ReplaceRuleService {
  ReplaceRuleService(this._daos);

  final StoreDaos _daos;
  ReplaceRuleDao get _dao => _daos.replaceRule;

  List<ReplaceRuleView> list() {
    final groups = <String, List<ReplaceRule>>{};
    for (final rule in _dao.all) {
      groups.putIfAbsent(_key(rule.name, rule.group), () => []).add(rule);
    }
    return [
      for (final rules in groups.values)
        ReplaceRuleView(
          id: rules.first.id,
          name: rules.first.name,
          group: rules.first.group ?? '',
          enabled: rules.first.isEnabled,
          order: rules.first.order,
          raw: _encodeRaw(rules),
        ),
    ]..sort((a, b) => a.order.compareTo(b.order));
  }

  ReplaceRuleView get(int id) {
    final first = _requireFirst(id);
    return _viewOf(first);
  }

  /// 保存一组规则；`raw=""` 兜成 `[]`（清空该组）。
  ReplaceRuleView save(
    int id,
    String name,
    String group,
    String raw,
    bool enabled,
    int order,
  ) {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '规则名不能为空');
    }
    final trimmedGroup = group.trim();
    final rules = _decodeRaw(raw);
    final baseId = id > 0
        ? id
        : _dao.all.fold<int>(0, (max, rule) => rule.id > max ? rule.id : max) + 1;

    runInTransaction(_daos.db, () {
      if (id > 0) {
        final existing = _requireFirst(id);
        _deleteGroup(existing);
      } else {
        // 同名同组已存在时覆盖，避免 Save(0) 造出重复组。
        for (final old in _dao.all) {
          if (old.name == trimmedName && (old.group ?? '') == trimmedGroup) {
            _deleteGroup(old);
            break;
          }
        }
      }
      for (var i = 0; i < rules.length; i++) {
        final rule = rules[i]
          ..id = baseId + i
          ..name = trimmedName
          ..group = trimmedGroup
          ..isEnabled = enabled
          ..order = order;
        _dao.insert(rule);
      }
    });
    // 空 raw 不落任何行，不能回读；直接构造回执，raw 统一是 []。
    if (rules.isEmpty) {
      return ReplaceRuleView(
        id: baseId,
        name: trimmedName,
        group: trimmedGroup,
        enabled: enabled,
        order: order,
        raw: '[]',
      );
    }
    return get(baseId);
  }

  void remove(int id) {
    final first = _requireFirst(id);
    runInTransaction(_daos.db, () => _deleteGroup(first));
  }

  void setEnabled(int id, bool enabled) {
    final first = _requireFirst(id);
    final members = _membersOf(first);
    runInTransaction(_daos.db, () {
      for (final rule in members) {
        _dao.update(rule.copyWith(isEnabled: enabled));
      }
    });
  }

  /// 导入 base64 文本（兼容 `replaceRule` 字段包裹）。
  ReplaceRuleImportResult importBase64(String dataBase64, {bool overwrite = false}) {
    List<int> bytes;
    try {
      bytes = base64Decode(dataBase64.trim());
    } on Object catch (e) {
      return ReplaceRuleImportResult(
        failures: [ReplaceRuleFailure(name: '', reason: 'base64 解码失败: $e')],
      );
    }
    return importText(utf8.decode(bytes, allowMalformed: true), overwrite: overwrite);
  }

  ReplaceRuleImportResult importText(String text, {bool overwrite = false}) {
    final trimmed = _stripBom(text).trim();
    Object? decoded;
    try {
      decoded = jsonDecode(_lenientJson(trimmed));
    } on FormatException catch (e) {
      return ReplaceRuleImportResult(
        failures: [ReplaceRuleFailure(name: '', reason: 'JSON 解析失败: ${e.message}')],
      );
    }
    Object? items = decoded;
    if (decoded is Map) {
      items = decoded['replaceRule'] ?? decoded['rules'] ?? decoded;
    }
    if (items is! List) {
      return const ReplaceRuleImportResult(
        failures: [ReplaceRuleFailure(name: '', reason: '顶层不是数组')],
      );
    }

    final imported = <ReplaceRuleView>[];
    final failures = <ReplaceRuleFailure>[];
    var updated = 0;
    var skipped = 0;

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final name = item is Map ? '${item['name'] ?? ''}' : '';
      try {
        if (item is! Map) {
          failures.add(ReplaceRuleFailure(
            name: name,
            reason: '第 ${i + 1} 项不是对象',
          ));
          continue;
        }
        final map = item.cast<String, Object?>();
        final ruleName = '${map['name'] ?? ''}'.trim();
        if (ruleName.isEmpty) {
          failures.add(const ReplaceRuleFailure(name: '', reason: '缺少 name'));
          continue;
        }
        final group = '${map['group'] ?? ''}';
        final existing = _dao.all.where(
          (rule) => rule.name == ruleName && (rule.group ?? '') == group,
        );
        if (existing.isNotEmpty) {
          if (!overwrite) {
            skipped++;
            continue;
          }
          updated++;
        }
        final raw = map['raw'] is List
            ? _encodeMaps((map['raw'] as List).cast<Map<String, Object?>>())
            : '${map['raw'] ?? '[]'}';
        final view = save(
          existing.isEmpty ? 0 : existing.first.id,
          ruleName,
          group,
          raw,
          map['enabled'] == null ? true : _asBool(map['enabled']),
          map['order'] is num ? (map['order'] as num).toInt() : 0,
        );
        if (existing.isEmpty) imported.add(view);
      } on Object catch (e) {
        failures.add(ReplaceRuleFailure(name: name, reason: '$e'));
      }
    }
    return ReplaceRuleImportResult(
      imported: imported.length,
      updated: updated,
      skipped: skipped,
      rules: imported,
      failures: failures,
    );
  }

  /// 导出选中组的 JSON 数组；`ids` 空导出全部。
  String exportJson(List<int> ids) {
    final selected = ids.isEmpty ? list() : [for (final id in ids) get(id)];
    final maps = <Map<String, Object?>>[];
    for (final view in selected) {
      final array = jsonDecode(view.raw.isEmpty ? '[]' : view.raw);
      if (array is! List) continue;
      for (final item in array) {
        if (item is! Map) continue;
        final map = item.cast<String, Object?>();
        maps.add(<String, Object?>{
          ...map,
          'name': view.name,
          'group': view.group,
          'enabled': view.enabled,
          'order': view.order,
        });
      }
    }
    return const JsonEncoder.withIndent('  ').convert(maps);
  }

  String exportBase64(List<int> ids) => base64Encode(utf8.encode(exportJson(ids)));

  // ----------------------------------------------------------------------

  ReplaceRule _requireFirst(int id) {
    final rule = _dao.findById(id);
    if (rule == null) {
      throw LegadoException(ErrorCode.notFound, '替换规则不存在: $id');
    }
    return rule;
  }

  List<ReplaceRule> _membersOf(ReplaceRule first) => _dao.all
      .where(
        (rule) =>
            rule.name == first.name && (rule.group ?? '') == (first.group ?? ''),
      )
      .toList();

  ReplaceRuleView _viewOf(ReplaceRule first) {
    final rules = _membersOf(first);
    return ReplaceRuleView(
      id: first.id,
      name: first.name,
      group: first.group ?? '',
      enabled: first.isEnabled,
      order: first.order,
      raw: _encodeRaw(rules),
    );
  }

  void _deleteGroup(ReplaceRule first) {
    for (final rule in _membersOf(first)) {
      _dao.delete(rule);
    }
  }

  String _key(String name, String? group) => '$name\u0000${group ?? ''}';

  List<ReplaceRule> _decodeRaw(String raw) {
    if (raw.trim().isEmpty) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(_lenientJson(raw));
    } on FormatException catch (e) {
      throw LegadoException(ErrorCode.invalid, '规则 JSON 解析失败: ${e.message}');
    }
    if (decoded is! List) {
      throw const LegadoException(ErrorCode.invalid, 'raw 必须是规则数组');
    }
    final out = <ReplaceRule>[];
    for (final item in decoded) {
      if (item is! Map) {
        throw const LegadoException(ErrorCode.invalid, 'raw 的元素必须是对象');
      }
      final map = item.cast<String, Object?>();
      final pattern = '${map['pattern'] ?? ''}';
      if (pattern.isEmpty) {
        throw const LegadoException(ErrorCode.invalid, '规则缺少 pattern');
      }
      out.add(ReplaceRule(
        pattern: pattern,
        replacement: '${map['replacement'] ?? ''}',
        scope: map['scope'] == null ? null : '${map['scope']}',
        scopeTitle: _asBool(map['scopeTitle']),
        scopeContent: map['scopeContent'] == null ? true : _asBool(map['scopeContent']),
        excludeScope:
            map['excludeScope'] == null ? null : '${map['excludeScope']}',
        isRegex: map['isRegex'] == null ? true : _asBool(map['isRegex']),
        timeoutMillisecond: map['timeoutMillisecond'] is num
            ? (map['timeoutMillisecond'] as num).toInt()
            : 3000,
      ));
    }
    return out;
  }

  String _encodeRaw(List<ReplaceRule> rules) => _encodeMaps([
        for (final rule in rules)
          <String, Object?>{
            'pattern': rule.pattern,
            'replacement': rule.replacement,
            'scope': rule.scope,
            'scopeTitle': rule.scopeTitle,
            'scopeContent': rule.scopeContent,
            'excludeScope': rule.excludeScope,
            'isRegex': rule.isRegex,
            'timeoutMillisecond': rule.timeoutMillisecond,
          },
      ]);

  String _encodeMaps(List<Map<String, Object?>> maps) =>
      const JsonEncoder.withIndent('  ').convert(maps);

  bool _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      return switch (value.toLowerCase()) {
        'true' || '1' || 'yes' => true,
        _ => false,
      };
    }
    return false;
  }

  String _stripBom(String text) =>
      text.startsWith('\uFEFF') ? text.substring(1) : text;
}

/// 宽松 JSON：去 `//` 注释与尾逗号，但保留字符串里的 `//`。
String _lenientJson(String input) {
  final buffer = StringBuffer();
  var inString = false;
  var escaped = false;
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (inString) {
      buffer.write(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      i++;
      continue;
    }
    if (ch == '"') {
      inString = true;
      buffer.write(ch);
      i++;
      continue;
    }
    if (ch == '/' && i + 1 < input.length && input[i + 1] == '/') {
      while (i < input.length && input[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == ',') {
      var j = i + 1;
      while (j < input.length && (input[j] == ' ' || input[j] == '\n' ||
          input[j] == '\r' || input[j] == '\t')) {
        j++;
      }
      if (j < input.length && (input[j] == ']' || input[j] == '}')) {
        i++;
        continue;
      }
    }
    buffer.write(ch);
    i++;
  }
  return buffer.toString();
}
