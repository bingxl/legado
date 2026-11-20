import 'dart:convert';

import '../../domain/domain.dart';
import '../../kernel/errors.dart';
import '../../net/net.dart';
import '../../store/dao/book_source_dao.dart';
import '../../store/database.dart';
import '../../store/store.dart';
import 'source_group.dart';
import 'source_io.dart';

/// 书源管理结果项（`Source.Validate` 用）。
class SourceCheckIssue {
  const SourceCheckIssue({
    required this.level,
    required this.field,
    required this.message,
  });

  final String level;
  final String field;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
        'level': level,
        'field': field,
        'message': message,
      };
}

class SourceCheckResult {
  const SourceCheckResult({
    required this.sourceId,
    required this.sourceName,
    required this.ok,
    required this.issues,
  });

  final int sourceId;
  final String sourceName;
  final bool ok;
  final List<SourceCheckIssue> issues;

  Map<String, Object?> toJson() => <String, Object?>{
        'sourceId': sourceId,
        'sourceName': sourceName,
        'ok': ok,
        'issues': [for (final issue in issues) issue.toJson()],
      };
}

/// 订阅同步结果项。
class SubscriptionSyncResult {
  const SubscriptionSyncResult({
    required this.subscriptionId,
    required this.subscriptionName,
    this.imported = 0,
    this.updated = 0,
    this.failed = 0,
    this.error = '',
  });

  final int subscriptionId;
  final String subscriptionName;
  final int imported;
  final int updated;
  final int failed;
  final String error;

  Map<String, Object?> toJson() => <String, Object?>{
        'subscriptionId': subscriptionId,
        'subscriptionName': subscriptionName,
        'imported': imported,
        'updated': updated,
        'failed': failed,
        'error': error,
      };
}

/// 书源域的本地管理部分：CRUD / 导入导出 / 分组 / 批量排序 / 变量 / 订阅。
///
/// 搜索、发现、试读等需要规则引擎的链路在 `SourceFetchService` 里，
/// 两者共享同一批 DAO，但职责分开，避免这个类变成第二个「胖 app」。
class SourceService {
  SourceService(this._daos)
    : _io = SourceIoService(_daos),
      _groups = SourceGroupService(_daos),
      _net = NetClient();

  final StoreDaos _daos;
  final SourceIoService _io;
  final SourceGroupService _groups;
  final NetClient _net;

  BookSourceDao get _dao => _daos.bookSource;

  void close() => _net.close();

  // ---- CRUD -----------------------------------------------------------

  List<SourceView> list(String group) {
    final sources = group.trim().isEmpty ? _dao.all : _dao.groupSearch(group.trim());
    return [for (final source in sources) _brief(source)];
  }

  SourceView get(int id) {
    final source = _require(id);
    final view = _brief(source);
    return SourceView(
      id: view.id,
      name: view.name,
      group: view.group,
      url: view.url,
      enabled: view.enabled,
      order: view.order,
      comment: view.comment,
      raw: const JsonEncoder.withIndent('  ').convert(source.toJson()),
      type: view.type,
      enabledExplore: view.enabledExplore,
      hasExploreUrl: view.hasExploreUrl,
      hasSearchUrl: view.hasSearchUrl,
      hasLoginUrl: view.hasLoginUrl,
      enabledCookieJar: view.enabledCookieJar,
      weight: view.weight,
      respondTime: view.respondTime,
      variableComment: view.variableComment,
      lastUpdateAt: view.lastUpdateAt,
      createdAt: view.createdAt,
    );
  }

  /// 8 个参数的位置顺序不能错；`raw` 缺 URL 时用 [url] 补全。
  SourceView save(
    int id,
    String name,
    String group,
    String url,
    String comment,
    String raw,
    bool enabled,
    int order,
  ) {
    final trimmedUrl = url.trim();
    final trimmedName = name.trim();
    if (trimmedUrl.isEmpty && raw.trim().isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '缺少书源 URL 与 raw');
    }

    Map<String, Object?> map;
    try {
      final decoded = jsonDecode(_looseJson(raw.trim().isEmpty ? '{}' : raw));
      if (decoded is! Map) {
        throw const LegadoException(ErrorCode.invalid, 'raw 必须是书源 JSON 对象');
      }
      map = decoded.cast<String, Object?>();
    } on FormatException catch (e) {
      throw LegadoException(ErrorCode.invalid, 'raw JSON 解析失败: ${e.message}');
    }
    if ((map['bookSourceUrl'] == null || '${map['bookSourceUrl']}'.isEmpty) &&
        trimmedUrl.isNotEmpty) {
      map = {...map, 'bookSourceUrl': trimmedUrl};
    }
    if (trimmedName.isNotEmpty) map = {...map, 'bookSourceName': trimmedName};
    if (group.isNotEmpty) map = {...map, 'bookSourceGroup': group};
    if (comment.isNotEmpty) map = {...map, 'bookSourceComment': comment};
    map = {
      ...map,
      'enabled': enabled,
      'customOrder': order,
    };

    final source = BookSource.fromJson(map);
    if (source.bookSourceUrl.trim().isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '缺少 bookSourceUrl');
    }
    final old = id > 0 ? _sourceById(id) : _dao.getBookSource(source.bookSourceUrl);
    if (id > 0 && old == null) {
      throw LegadoException(ErrorCode.notFound, '书源不存在: $id');
    }
    if (old == null) {
      // id=0 且 URL 没出现过：新增。DAO 的 update 是纯 UPDATE，不会插入。
      _dao.insert(source);
    } else if (old.bookSourceUrl != source.bookSourceUrl) {
      // 换 URL 等同 key 变化，INSERT OR REPLACE 会级联删掉 searchBooks。
      _dao.delete(old);
      _dao.insert(source);
    } else {
      _dao.update(source);
    }
    return _brief(source);
  }

  void delete(int id) => _dao.delete(_require(id));

  void setEnabled(int id, bool enabled) => _dao.enable(_require(id).bookSourceUrl, enabled);

  // ---- 导入导出与校验 -------------------------------------------------

  Future<SourceImportResult> importBase64(String data, bool overwrite) =>
      _io.importBase64(data, overwrite: overwrite);

  Future<SourceImportResult> importFromURL(String rawURL, bool overwrite) async {
    final url = rawURL.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw LegadoException(ErrorCode.invalid, '非法订阅地址: $rawURL');
    }
    final response = await _net.get(Uri.parse(url));
    if (!response.isSuccess) {
      throw LegadoException(
        ErrorCode.netTimeout,
        '拉取书源失败: HTTP ${response.statusCode}',
      );
    }
    return _io.importText(response.text(), overwrite: overwrite);
  }

  Future<String> export(List<int> ids) => _io.exportBase64(ids);

  /// 结构校验：不联网，只看规则字段是否齐备、JSON 是否合法。
  ///
  /// `items` 的键兼容 PascalCase 与 camelCase（旧 Go 结构体无 json tag）。
  List<SourceCheckResult> validate(List<int> ids, Map<String, Object?> items) {
    final selected = ids.isEmpty
        ? _dao.all.where((source) => source.enabled).toList()
        : [for (final id in ids) _require(id)];
    final check = <String, bool>{
      for (final entry in items.entries) entry.key.toLowerCase(): _flag(entry.value),
    };
    bool want(String key) => check[key] ?? false;
    final out = <SourceCheckResult>[];

    for (final source in selected) {
      final issues = <SourceCheckIssue>[];
      void require(String field, Object? value, String message) {
        if (value == null || '$value'.trim().isEmpty) {
          issues.add(SourceCheckIssue(level: 'error', field: field, message: message));
        }
      }

      require('bookSourceUrl', source.bookSourceUrl, '缺少书源 URL');
      require('bookSourceName', source.bookSourceName, '缺少书源名称');
      if (want('search') || want('searchurl')) {
        require('searchUrl', source.searchUrl, '缺少搜索地址');
        require('ruleSearch', source.ruleSearch, '缺少搜索规则');
      }
      if (want('info')) require('ruleBookInfo', source.ruleBookInfo, '缺少详情规则');
      if (want('toc')) require('ruleToc', source.ruleToc, '缺少目录规则');
      if (want('content')) {
        require('ruleContent', source.ruleContent, '缺少正文规则');
      }
      final keyword = items['Keyword'] ?? items['keyword'];
      if (keyword is String && keyword.isNotEmpty) {
        if (source.searchUrl == null || source.searchUrl!.isEmpty) {
          issues.add(const SourceCheckIssue(
            level: 'info',
            field: 'Keyword',
            message: '该源没有搜索地址，跳过关键词校验',
          ));
        }
      }
      for (final field in const [
        'ruleSearch',
        'ruleBookInfo',
        'ruleToc',
        'ruleContent',
        'ruleExplore',
      ]) {
        final text = switch (field) {
          'ruleSearch' => source.ruleSearch,
          'ruleBookInfo' => source.ruleBookInfo,
          'ruleToc' => source.ruleToc,
          'ruleContent' => source.ruleContent,
          _ => source.ruleExplore,
        };
        if (text == null || text.isEmpty) continue;
        try {
          jsonDecode(text);
        } on FormatException {
          // 规则允许纯字符串简写，jsonDecode 失败不代表非法。
        }
      }
      out.add(SourceCheckResult(
        sourceId: _dao.rowIdOf(source.bookSourceUrl) ?? 0,
        sourceName: source.bookSourceName,
        ok: issues.every((issue) => issue.level != 'error'),
        issues: issues,
      ));
    }
    return out;
  }

  // ---- 分组 -----------------------------------------------------------

  List<SourceGroupView> listGroups() => _groups.listGroups();

  /// 「新增分组」= 把未分组书源归入该组，返回受影响条数。
  int addGroupToNoGroup(String group) {
    final target = group.trim();
    if (target.isEmpty) return 0;
    var affected = 0;
    runInTransaction(_daos.db, () {
      for (final source in _dao.all.where((item) => item.groups.isEmpty)) {
        _dao.upGroup(source.bookSourceUrl, target);
        affected++;
      }
    });
    return affected;
  }

  Future<int> renameGroup(String oldName, String newName) =>
      _groups.rename(oldName, newName);

  Future<int> deleteGroup(String name) => _groups.remove(name);

  void addToGroup(List<int> ids, String group) {
    final target = group.trim();
    if (target.isEmpty) return;
    runInTransaction(_daos.db, () {
      for (final id in ids) {
        final source = _sourceById(id);
        if (source == null) continue;
        final current = source.groups;
        if (!current.contains(target)) _dao.upGroup(source.bookSourceUrl, [...current, target].join(','));
      }
    });
  }

  void removeFromGroup(List<int> ids, String group) {
    final target = group.trim();
    if (target.isEmpty) return;
    runInTransaction(_daos.db, () {
      for (final id in ids) {
        final source = _sourceById(id);
        if (source == null) continue;
        final current = source.groups;
        if (current.contains(target)) {
          _dao.upGroup(
            source.bookSourceUrl,
            [for (final item in current) if (item != target) item].join(','),
          );
        }
      }
    });
  }

  // ---- 批量与排序 -----------------------------------------------------

  void setEnabledBatch(List<int> ids, bool enabled) {
    runInTransaction(_daos.db, () {
      for (final id in ids) {
        final source = _sourceById(id);
        if (source != null) _dao.enable(source.bookSourceUrl, enabled);
      }
    });
  }

  /// `enabledExplore` 只存在 raw JSON 里：用 patchRaw 改写再落库。
  void setEnabledExploreBatch(List<int> ids, bool enabled) {
    runInTransaction(_daos.db, () {
      for (final id in ids) {
        final source = _sourceById(id);
        if (source == null) continue;
        _dao.update(source.patchRaw(<String, Object?>{'enabledExplore': enabled}));
      }
    });
  }

  void deleteBatch(List<int> ids) {
    runInTransaction(_daos.db, () {
      for (final id in ids) {
        final source = _sourceById(id);
        if (source != null) _dao.delete(source);
      }
    });
  }

  void moveTop(List<int> ids) {
    final selected = <BookSource>[];
    for (final id in ids) {
      final source = _sourceById(id);
      if (source != null) selected.add(source);
    }
    if (selected.isEmpty) return;
    runInTransaction(_daos.db, () {
      var order = _dao.minOrder - selected.length;
      for (final source in selected) {
        _dao.upOrder(source.bookSourceUrl, order++);
      }
    });
  }

  void moveBottom(List<int> ids) {
    final selected = <BookSource>[];
    for (final id in ids) {
      final source = _sourceById(id);
      if (source != null) selected.add(source);
    }
    if (selected.isEmpty) return;
    runInTransaction(_daos.db, () {
      var order = _dao.maxOrder + 1;
      for (final source in selected) {
        _dao.upOrder(source.bookSourceUrl, order++);
      }
    });
  }

  /// [ids] 是拖拽后的完整可见顺序；未出现的保持原相对位置。
  void reorder(List<int> ids) {
    final byId = {for (final source in _dao.all) _dao.rowIdOf(source.bookSourceUrl): source};
    final order = <BookSource>[];
    for (final id in ids) {
      final source = byId[id];
      if (source != null && !order.contains(source)) order.add(source);
    }
    for (final source in _dao.all) {
      if (!order.contains(source)) order.add(source);
    }
    runInTransaction(_daos.db, () {
      for (var i = 0; i < order.length; i++) {
        _dao.upOrder(order[i].bookSourceUrl, i);
      }
    });
  }

  // ---- 变量 / Cookie --------------------------------------------------

  Map<String, Object?> getVariable(int id) {
    final source = _require(id);
    final raw = _daos.cache.get('sourceVariable_${source.bookSourceUrl}')?.value ?? '';
    return <String, Object?>{
      'sourceId': id,
      'name': source.bookSourceName,
      'url': source.bookSourceUrl,
      'variable': raw.isEmpty ? '{}' : raw,
      'comment': source.variableComment ?? '',
    };
  }

  void setVariable(int id, String variable) {
    final source = _require(id);
    final key = 'sourceVariable_${source.bookSourceUrl}';
    if (variable.trim().isEmpty) {
      _daos.cache.delete(key);
    } else {
      _daos.cache.put(key, variable);
    }
  }

  void clearCookie(int id) =>
      _daos.cache.deleteSourceVariables(_require(id).bookSourceUrl);

  // ---- 订阅源 ---------------------------------------------------------

  List<Map<String, Object?>> listSubscriptions() => [
        for (final sub in _daos.ruleSub.all) _subscriptionView(sub),
      ];

  Map<String, Object?> getSubscription(int id) {
    final sub = _daos.ruleSub.all.where((item) => item.id == id).firstOrNull;
    if (sub == null) {
      throw LegadoException(ErrorCode.notFound, '订阅源不存在: $id');
    }
    return _subscriptionView(sub);
  }

  Map<String, Object?> saveSubscription(
    int id,
    String name,
    String url,
    bool enabled,
    int order,
  ) {
    final existing = id > 0
        ? _daos.ruleSub.all.where((item) => item.id == id).firstOrNull
        : null;
    if (id > 0 && existing == null) {
      throw LegadoException(ErrorCode.notFound, '订阅源不存在: $id');
    }
    final sub = existing ?? RuleSub();
    sub
      ..id = id > 0 ? id : _nextSubId()
      ..name = name.trim()
      ..url = url.trim()
      ..type = 0
      ..customOrder = order
      ..autoUpdate = enabled
      ..update = DateTime.now().millisecondsSinceEpoch;
    if (existing == null) {
      _daos.ruleSub.insert(sub);
    } else {
      _daos.ruleSub.update(sub);
    }
    return _subscriptionView(sub);
  }

  void deleteSubscription(int id) {
    final sub = _daos.ruleSub.all.where((item) => item.id == id).firstOrNull;
    if (sub != null) _daos.ruleSub.delete(sub);
  }

  void setSubscriptionEnabled(int id, bool enabled) {
    final sub = _daos.ruleSub.all.where((item) => item.id == id).firstOrNull;
    if (sub == null) return;
    sub.autoUpdate = enabled;
    _daos.ruleSub.update(sub);
  }

  Future<SourceImportResult> syncSubscription(int id) async {
    final sub = _daos.ruleSub.all.where((item) => item.id == id).firstOrNull;
    if (sub == null) {
      throw LegadoException(ErrorCode.notFound, '订阅源不存在: $id');
    }
    final result = await importFromURL(sub.url, true);
    sub.update = DateTime.now().millisecondsSinceEpoch;
    _daos.ruleSub.update(sub);
    return result;
  }

  /// 逐条串行同步（不并发），单条失败记进 error 后继续。
  Future<List<SubscriptionSyncResult>> syncAllSubscriptions() async {
    final out = <SubscriptionSyncResult>[];
    for (final sub in _daos.ruleSub.all.where((item) => item.autoUpdate)) {
      try {
        final result = await syncSubscription(sub.id);
        out.add(SubscriptionSyncResult(
          subscriptionId: sub.id,
          subscriptionName: sub.name,
          imported: result.imported,
          updated: result.updated,
          failed: result.failures.length,
        ));
      } on Object catch (e) {
        out.add(SubscriptionSyncResult(
          subscriptionId: sub.id,
          subscriptionName: sub.name,
          error: '$e',
          failed: 1,
        ));
      }
    }
    return out;
  }

  // ---- helpers --------------------------------------------------------

  BookSource? _sourceById(int id) {
    final sources = _dao.getByRowIds([id]);
    return sources.isEmpty ? null : sources.first;
  }

  BookSource _require(int id) {
    final source = _sourceById(id);
    if (source == null) {
      throw LegadoException(ErrorCode.notFound, '书源不存在: $id');
    }
    return source;
  }

  SourceView _brief(BookSource source) => SourceView.brief(
        source,
        id: _dao.rowIdOf(source.bookSourceUrl) ?? 0,
      );

  Map<String, Object?> _subscriptionView(RuleSub sub) => <String, Object?>{
        'id': sub.id,
        'name': sub.name,
        'url': sub.url,
        'enabled': sub.autoUpdate,
        'order': sub.customOrder,
        'type': sub.type,
        'updatedAt': sub.update > 0
            ? DateTime.fromMillisecondsSinceEpoch(sub.update, isUtc: true)
                .toIso8601String()
            : null,
      };

  int _nextSubId() {
    final max = _daos.ruleSub.all.fold<int>(0, (m, sub) => sub.id > m ? sub.id : m);
    return max + 1;
  }

  bool _flag(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      return switch (value.toLowerCase()) {
        'true' || '1' || 'yes' || 'on' => true,
        _ => false,
      };
    }
    return false;
  }

  /// 宽松 JSON：去掉 `//` 注释与尾逗号，字符串里的 `//` 原样保留。
  String _looseJson(String input) {
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
}
