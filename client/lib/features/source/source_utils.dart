import 'dart:convert';

/// 书源页面的纯函数工具。
///
/// 单独成文件的原因：这些逻辑（域名解析、分组拆分、raw 校验、调试阶段归类）
/// 不依赖 widget，可以直接在 `test/source/` 下单测，页面改动时回归成本低。
class SourceUtils {
  SourceUtils._();

  /// 从书源 URL 取域名，失败时退化为原串。
  ///
  /// 列表里显示域名而不是完整 URL：书源 URL 常常很长且带路径，
  /// 用户辨认「这个源是哪家站」只看域名就够了（原生列表也是这个信息密度）。
  static String domainOf(String url) {
    final u = Uri.tryParse(url.trim());
    if (u != null && u.host.isNotEmpty) return u.host;
    return url.trim();
  }

  /// 书源分组字段是「多个分组用逗号/分号分隔」的字符串。
  static List<String> splitGroups(String? group) {
    if (group == null || group.trim().isEmpty) return const [];
    return group
        .split(RegExp(r'[,;，；|]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  /// 本地过滤：命中名称、URL、分组任一即可。
  static bool matchesQuery(Map<String, dynamic> source, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final name = '${source['name'] ?? ''}'.toLowerCase();
    final url = '${source['url'] ?? ''}'.toLowerCase();
    final group = '${source['group'] ?? ''}'.toLowerCase();
    return name.contains(q) || url.contains(q) || group.contains(q);
  }

  /// 判断书源是否属于某个分组；group 为空表示「全部」。
  static bool inGroup(Map<String, dynamic> source, String group) {
    if (group.isEmpty) return true;
    return splitGroups('${source['group'] ?? ''}').contains(group);
  }

  /// 基础 JSON 校验：返回 null 表示没问题，否则返回给用户看的错误文案。
  ///
  /// 只做「能不能解析成对象」这一层，不校验字段语义——书源规则字段太多，
  /// 语义校验交给 core 的 `Source.Validate`，这里只拦住手滑写坏的 JSON。
  static String? checkRawJson(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      return 'JSON 格式错误：${e.message}';
    }
    if (decoded is! Map) return '书源应为一个 JSON 对象';
    return null;
  }

  /// 尽力把 raw 格式化成两空格缩进；解析失败时原样返回。
  static String prettyJson(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return raw;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } on FormatException {
      return raw;
    }
  }

  /// 从 raw 中提取管理字段，供「新建时只贴了 JSON」的场景补齐表单。
  ///
  /// 键名与原版 Legado 书源格式保持一致；缺失的字段不出现在结果里。
  static Map<String, String> extractRawFields(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const {};
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const {};
    }
    if (decoded is! Map) return const {};
    final out = <String, String>{};
    void put(String key, String target) {
      final v = decoded[key];
      if (v is String && v.trim().isNotEmpty) out[target] = v.trim();
    }

    put('bookSourceName', 'name');
    put('bookSourceGroup', 'group');
    put('bookSourceUrl', 'url');
    put('bookSourceComment', 'comment');
    return out;
  }

  /// 导入结果压成一行提示：新增 x / 更新 y / 跳过 z / 失败 n。
  static String importSummary(Map<String, dynamic> result) {
    int n(String key) => (result[key] as num?)?.toInt() ?? 0;
    final parts = <String>[
      '新增 ${n('imported')}',
      '更新 ${n('updated')}',
      '跳过 ${n('skipped')}',
    ];
    final failures = result['failures'];
    if (failures is List && failures.isNotEmpty) {
      parts.add('失败 ${failures.length}');
    }
    return parts.join(' / ');
  }

  /// 导入失败的第一条原因，用于提示里补一句具体信息。
  static String? firstImportFailure(Map<String, dynamic> result) {
    final failures = result['failures'];
    if (failures is! List || failures.isEmpty) return null;
    final first = failures.first;
    if (first is Map) {
      final name = '${first['name'] ?? ''}';
      final reason = '${first['reason'] ?? ''}';
      final label = name.isEmpty ? '未知书源' : name;
      return reason.isEmpty ? label : '$label：$reason';
    }
    return '$first';
  }

  /// ISO 时间串 → `HH:mm:ss`；解析失败返回空串。
  static String timeOfDay(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  /// ISO 时间串 → `yyyy-MM-dd`；解析失败返回 `—`。
  static String dateOf(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '—';
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  // ── 调试条目的阶段归类 ──────────────────────────────────

  /// 调试/校验阶段的展示顺序。
  static const stageOrder = <String>[
    '基本信息',
    '规则完整性',
    '搜索',
    '发现',
    '详情',
    '目录',
    '正文',
    '其他',
  ];

  /// 把 core 返回的 issue.field 归到可读阶段。
  ///
  /// 字段命名来自引擎：`bookSource*` 是基础字段，`ruleSearch.*` 这类是规则完整性，
  /// 联网阶段的 field 直接是 `search` / `info` / `toc` / `content` / `explore`。
  static String stageOfField(String field) {
    final f = field.trim();
    if (f.isEmpty) return '其他';
    if (f == 'search') return '搜索';
    if (f == 'explore') return '发现';
    if (f == 'info') return '详情';
    if (f == 'toc') return '目录';
    if (f == 'content') return '正文';
    if (f.startsWith('rule')) return '规则完整性';
    if (f.startsWith('bookSource')) return '基本信息';
    return '其他';
  }

  /// 阶段排序用的小整数，未知阶段排最后。
  static int stageRank(String stage) {
    final i = stageOrder.indexOf(stage);
    return i < 0 ? stageOrder.length : i;
  }

  /// 是否算「未命中/失败」——失败条目在界面上标红。
  ///
  /// core 的 level 只有 error/warning/info；其中「无结果」「失败」这类
  /// info 级消息其实也是没跑通，所以文案里带关键词时同样按未命中处理。
  static bool isMiss(String level, String message) {
    if (level == 'error') return true;
    return message.contains('失败') ||
        message.contains('无结果') ||
        message.contains('为空') ||
        message.contains('无法');
  }

  /// 从校验消息里抽命中数：`命中 12 条`、`共 340 章`、`正文解析成功(1024 字)`。
  static int? hitCountOf(String message) {
    final patterns = <RegExp>[
      RegExp(r'命中\s*(\d+)\s*条'),
      RegExp(r'共\s*(\d+)\s*章'),
      RegExp(r'\((\d+)\s*字\)'),
      RegExp(r'(\d+)\s*条'),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(message);
      if (m != null) {
        final v = int.tryParse(m.group(1) ?? '');
        if (v != null) return v;
      }
    }
    return null;
  }
}
