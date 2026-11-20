import 'dart:convert';

import '../../domain/domain.dart';
import '../../store/dao/book_source_dao.dart';
import '../../store/database.dart';
import '../../store/store.dart';

/// 导入失败的一条记录。
class ImportFailure {
  const ImportFailure({this.name = '', this.url = '', required this.reason});

  final String name;
  final String url;
  final String reason;

  Map<String, Object?> toJson() => {
        'name': name,
        'url': url,
        'reason': reason,
      };

  @override
  String toString() => 'ImportFailure($name / $url: $reason)';
}

/// 书源简报，对应契约 `SourceView`（列表场景 `raw` 恒为空串）。
class SourceView {
  const SourceView({
    required this.id,
    required this.name,
    required this.group,
    required this.url,
    required this.enabled,
    required this.order,
    required this.comment,
    required this.raw,
    required this.type,
    required this.enabledExplore,
    required this.hasExploreUrl,
    required this.hasLoginUrl,
    required this.hasSearchUrl,
    required this.enabledCookieJar,
    required this.weight,
    required this.respondTime,
    required this.variableComment,
    this.lastUpdateAt,
    this.createdAt = '',
  });

  /// `book_sources` 的 SQLite rowid。
  ///
  /// 原版 Kotlin 用 `bookSourceUrl` 作文本主键，没有 int 主键；契约里的 `id` 只能映射到
  /// 隐式 rowid。`update` 不会改变它，删除后重新导入会变。详见 `docs/进度-store.md`。
  final int id;
  final String name;
  final String group;
  final String url;
  final bool enabled;
  final int order;
  final String comment;
  final String raw;
  final int type;
  final bool enabledExplore;
  final bool hasExploreUrl;
  final bool hasLoginUrl;

  /// 是否配置了搜索地址（纯发现源为 false）。
  final bool hasSearchUrl;

  final bool? enabledCookieJar;
  final int weight;
  final int respondTime;
  final String variableComment;
  final String? lastUpdateAt;
  final String createdAt;

  factory SourceView.brief(BookSource source, {required int id}) => SourceView(
        id: id,
        name: source.bookSourceName,
        group: source.bookSourceGroup ?? '',
        url: source.bookSourceUrl,
        enabled: source.enabled,
        order: source.customOrder,
        comment: source.bookSourceComment ?? '',
        raw: '',
        type: source.bookSourceType,
        enabledExplore: source.enabledExplore,
        hasExploreUrl: (source.exploreUrl ?? '').trim().isNotEmpty,
        hasLoginUrl: (source.loginUrl ?? '').trim().isNotEmpty,
        hasSearchUrl: (source.searchUrl ?? '').trim().isNotEmpty,
        enabledCookieJar: source.enabledCookieJar,
        weight: source.weight,
        respondTime: source.respondTime,
        variableComment: source.variableComment ?? '',
        lastUpdateAt: _isoTime(source.lastUpdateTime),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'group': group,
        'url': url,
        'enabled': enabled,
        'order': order,
        'comment': comment,
        'raw': raw,
        'lastUpdateAt': lastUpdateAt,
        'createdAt': createdAt,
        'type': type,
        'enabledExplore': enabledExplore,
        'hasExploreUrl': hasExploreUrl,
        'hasLoginUrl': hasLoginUrl,
        'hasSearchUrl': hasSearchUrl,
        'enabledCookieJar': enabledCookieJar,
        'weight': weight,
        'respondTime': respondTime,
        'variableComment': variableComment,
      };
}

String? _isoTime(int millis) {
  if (millis <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toIso8601String();
}

/// 书源导入结果，对应契约 `SourceImportResult`。
class SourceImportResult {
  const SourceImportResult({
    this.imported = 0,
    this.updated = 0,
    this.skipped = 0,
    this.sources = const [],
    this.failures = const [],
  });

  final int imported;
  final int updated;
  final int skipped;

  /// 本次成功新增/更新的书源简报。
  final List<SourceView> sources;

  final List<ImportFailure> failures;

  bool get hasError => failures.isNotEmpty;

  Map<String, Object?> toJson() => {
        'imported': imported,
        'updated': updated,
        'skipped': skipped,
        'sources': [for (final source in sources) source.toJson()],
        'failures': [for (final failure in failures) failure.toJson()],
      };

  @override
  String toString() =>
      'SourceImportResult(imported: $imported, updated: $updated, '
      'skipped: $skipped, failures: ${failures.length})';
}

/// 书源导入导出。
///
/// 只依赖 store 层：解析文本 → [BookSource] → DAO。
/// 规则正文（JSON 列）原样透传，不做任何规则语义校验 —— 那是 rules 层的事。
class SourceIoService {
  SourceIoService(this._daos);

  final StoreDaos _daos;

  BookSourceDao get _dao => _daos.bookSource;

  /// 契约入口：`data` 是 base64（JSON 传不了裸二进制）。
  Future<SourceImportResult> importBase64(
    String dataBase64, {
    bool overwrite = false,
  }) async {
    List<int> bytes;
    try {
      bytes = base64Decode(dataBase64.trim());
    } catch (e) {
      return SourceImportResult(
        failures: [ImportFailure(reason: 'base64 解码失败: $e')],
      );
    }
    return importText(utf8.decode(bytes, allowMalformed: true), overwrite: overwrite);
  }

  /// 导入书源文本。
  ///
  /// 支持：
  /// 1. 单个书源对象 `{...}`
  /// 2. 书源数组 `[{...}, {...}]`
  /// 3. `{"sources":[{...}]}` 包裹
  /// 4. Legado 备份文件 `{"bookSource":[{...}], ...}`（只取 `bookSource`，其余键忽略）
  /// 5. 逐行一个 URL（书源订阅地址），跳过并计入 `skipped`
  ///
  /// [overwrite] 为 false 时已存在的 `bookSourceUrl` 跳过；为 true 时走 `update`。
  /// **刻意不用 `INSERT OR REPLACE`**：REPLACE 会先 DELETE，`searchBooks` 上的外键是
  /// `ON DELETE CASCADE`，会把该源的搜索结果一起删掉。
  Future<SourceImportResult> importText(
    String text, {
    bool overwrite = false,
  }) async {
    final trimmed = _stripBomAndLeadingComments(text).trim();
    if (trimmed.isEmpty) {
      return const SourceImportResult(
        failures: [ImportFailure(reason: '输入为空')],
      );
    }

    final maps = <Map<String, Object?>>[];
    final failures = <ImportFailure>[];
    var lineSkipped = 0;

    final first = trimmed.codeUnitAt(0);
    final isJson = first == 0x7B /* { */ || first == 0x5B /* [ */;
    if (isJson) {
      Object? decoded;
      try {
        decoded = jsonDecode(_lenientJson(trimmed));
      } on FormatException catch (e) {
        return SourceImportResult(
          failures: [ImportFailure(reason: 'JSON 解析失败: ${e.message}')],
        );
      }
      _collectSources(decoded, maps, failures);
      if (maps.isEmpty && failures.isEmpty) {
        return const SourceImportResult(
          failures: [ImportFailure(reason: '没有找到任何书源')],
        );
      }
    } else {
      lineSkipped = _collectFromLines(trimmed, failures);
    }

    var imported = 0;
    var updated = 0;
    var skipped = 0;
    final touched = <BookSource>[];

    // 整批一个事务：几千条书源逐条提交会卡到不可用。
    // 单条失败只记录错误，不回滚整批 —— 导入场景更需要「能进多少进多少」。
    runInTransaction(_daos.db, () {
      for (var i = 0; i < maps.length; i++) {
        final map = maps[i];
        final fallbackName = _textOf(map['bookSourceName']);
        final fallbackUrl = _textOf(map['bookSourceUrl']);
        try {
          final source = _sourceFrom(map);
          if (source.bookSourceUrl.trim().isEmpty) {
            failures.add(ImportFailure(
              name: fallbackName,
              url: fallbackUrl,
              reason: '缺少 bookSourceUrl',
            ));
            continue;
          }
          if (!_dao.has(source.bookSourceUrl)) {
            _dao.insert(source);
            imported++;
            touched.add(source);
          } else if (overwrite) {
            _dao.update(source);
            updated++;
            touched.add(source);
          } else {
            skipped++;
          }
        } catch (e) {
          failures.add(ImportFailure(
            name: fallbackName,
            url: fallbackUrl,
            reason: '$e',
          ));
        }
      }
    });

    final sources = <SourceView>[];
    for (final source in touched) {
      sources.add(SourceView.brief(
        source,
        id: _dao.rowIdOf(source.bookSourceUrl) ?? 0,
      ));
    }

    return SourceImportResult(
      imported: imported,
      updated: updated,
      skipped: skipped + lineSkipped,
      sources: sources,
      failures: failures,
    );
  }

  /// 导出为 Legado 兼容 JSON 数组，按 `customOrder` 升序。
  ///
  /// [ids] 为空或 null 导出全部。
  Future<String> exportJson({List<int>? ids}) async {
    final selected = ids == null || ids.isEmpty
        ? _dao.all
        : _dao.getByRowIds(ids);
    final ordered = [...selected]
      ..sort((a, b) => a.customOrder.compareTo(b.customOrder));
    return const JsonEncoder.withIndent('  ')
        .convert(ordered.map((s) => s.toJson()).toList());
  }

  /// 契约入口：返回 base64 编码的 JSON 数组。
  Future<String> exportBase64(List<int> ids) async {
    final json = await exportJson(ids: ids);
    return base64Encode(utf8.encode(json));
  }

  /// 单条书源构造。
  ///
  /// 兼容两种「字段被包了一层」的输入：
  /// - `{...书源字段..., "raw": {...}}` / `raw` 为 JSON 字符串；
  /// - 顶层只有 `url` 的条目。
  /// 书源 URL 依次从 `bookSourceUrl`、`raw.bookSourceUrl`、顶层 `url` 取。
  BookSource _sourceFrom(Map<String, Object?> map) {
    final raw = map['raw'];
    final base = switch (raw) {
      Map() => raw.cast<String, Object?>(),
      String() when raw.trim().startsWith('{') => _tryDecodeMap(raw),
      _ => map,
    };
    final merged = raw == null || identical(base, map) ? base : {...base, ...map};

    final source = BookSource.fromJson(merged);
    if (source.bookSourceUrl.trim().isEmpty) {
      final fallback = _textOf(merged['url']).trim();
      source.bookSourceUrl = fallback.isEmpty ? _textOf(map['url']).trim() : fallback;
    }
    return source;
  }

  static Map<String, Object?> _tryDecodeMap(String text) {
    try {
      final decoded = jsonDecode(_lenientJson(text));
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // 落到下面的空 map：调用方会按「缺少 bookSourceUrl」报错。
    }
    return <String, Object?>{};
  }

  static String _textOf(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    return value.toString();
  }

  void _collectSources(
    Object? decoded,
    List<Map<String, Object?>> out,
    List<ImportFailure> failures,
  ) {
    if (decoded is List) {
      _appendList(decoded, out, failures, '第 %d 项不是对象');
      return;
    }
    if (decoded is Map) {
      final map = decoded.cast<String, Object?>();
      // Legado 备份文件：只取 bookSource，其余键（bookSourceSub 等）忽略。
      for (final key in const ['bookSource', 'sources']) {
        final wrapped = map[key];
        if (wrapped is List) {
          _appendList(wrapped, out, failures, '$key 第 %d 项不是对象');
          return;
        }
      }
      out.add(map);
      return;
    }
    failures.add(const ImportFailure(reason: '顶层不是对象或数组'));
  }

  void _appendList(
    List<dynamic> list,
    List<Map<String, Object?>> out,
    List<ImportFailure> failures,
    String reasonPattern,
  ) {
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      if (item is Map) {
        out.add(item.cast<String, Object?>());
      } else {
        failures.add(ImportFailure(
          reason: reasonPattern.replaceFirst('%d', '${i + 1}'),
        ));
      }
    }
  }

  /// 收集逐行输入里的 URL，返回被跳过的行数。
  int _collectFromLines(String text, List<ImportFailure> failures) {
    var skipped = 0;
    final lines = text.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (line.startsWith('//') || line.startsWith('#')) continue;
      if (_looksLikeUrl(line)) {
        skipped++;
        continue;
      }
      failures.add(ImportFailure(
        url: line,
        reason: '第 ${i + 1} 行不是合法书源或 URL',
      ));
    }
    return skipped;
  }

  static bool _looksLikeUrl(String line) {
    final lower = line.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }
}

/// 书源分组及其书源数量，对应契约 `SourceGroupView`。
class SourceGroupView {
  const SourceGroupView({required this.name, required this.count});

  final String name;
  final int count;

  Map<String, Object?> toJson() => {'name': name, 'count': count};
}

/// 去掉 BOM 与文件开头的整行注释（`//` / `#`）。
String _stripBomAndLeadingComments(String input) {
  var text = input;
  if (text.startsWith('\uFEFF')) {
    text = text.substring(1);
  }
  while (true) {
    final left = text.trimLeft();
    if (!left.startsWith('//') && !left.startsWith('#')) {
      return left;
    }
    final newline = left.indexOf('\n');
    if (newline < 0) return '';
    text = left.substring(newline + 1);
  }
}

/// 宽松 JSON 预处理。
///
/// 真实书源文件里确实存在三类脏数据：
/// - UTF-8 BOM
/// - 尾部多余逗号 `,}` / `,]`
/// - `//` 行注释
///
/// 逐字符扫描而不是正则：必须先知道「当前是否在字符串里」，
/// 否则 `https://...` 里的 `//` 会被当成注释，整份文件直接解析失败。
String _lenientJson(String input) {
  var text = input;
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
    text = text.substring(1);
  }

  final buffer = StringBuffer();
  var inString = false;
  var escaped = false;
  var i = 0;
  while (i < text.length) {
    final ch = text[i];

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

    if (ch == '/' && i + 1 < text.length && text[i + 1] == '/') {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
      continue;
    }

    if (ch == ',') {
      var j = i + 1;
      while (j < text.length && _isJsonSpace(text[j])) {
        j++;
      }
      if (j < text.length && (text[j] == ']' || text[j] == '}')) {
        i++; // 丢掉尾部逗号
        continue;
      }
    }

    buffer.write(ch);
    i++;
  }
  return buffer.toString();
}

bool _isJsonSpace(String ch) =>
    ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n';
