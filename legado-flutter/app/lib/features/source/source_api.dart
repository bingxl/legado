import 'dart:convert';

import '../../core/bridge/legado_client.dart';

/// 书源域的控制面方法封装。
///
/// 约定（MODULE-PLAN §1.1）：页面只描述意图，规则解析、网络请求全在 core 完成；
/// 本类只做「方法名 + 位置参数顺序」的映射，不在这里做任何业务判断。
///
/// 参数顺序来自 `legado methods Source`，改动前先用 CLI 核对。
class SourceApi {
  SourceApi._();

  static LegadoClient get _c => LegadoClient.instance;

  // ── 查询 ────────────────────────────────────────────────

  /// 列出书源。group 为空表示全部；返回值不含 raw（列表接口有意精简）。
  static Future<List<Map<String, dynamic>>> list({String group = ''}) {
    return _c.callList('Source.List', [group]);
  }

  /// 取单个书源（含 raw，用于编辑页）。
  static Future<Map<String, dynamic>> get(int id) async {
    final data = await _c.call('Source.Get', [id]);
    return (data as Map).cast<String, dynamic>();
  }

  /// 分组列表，含每组的书源数量。
  static Future<List<Map<String, dynamic>>> listGroups() {
    return _c.callList('Source.ListGroups');
  }

  // ── 增删改 ──────────────────────────────────────────────

  /// 新增或更新。id 为 0 时新增。
  ///
  /// raw 必须是书源原始 JSON 文本；core 会在缺少 bookSourceUrl 时用 url 补全。
  static Future<Map<String, dynamic>> save({
    required int id,
    required String name,
    required String group,
    required String url,
    required String comment,
    required String raw,
    required bool enabled,
    required int order,
  }) async {
    final data = await _c.call('Source.Save', [
      id,
      name,
      group,
      url,
      comment,
      raw,
      enabled,
      order,
    ]);
    return (data as Map).cast<String, dynamic>();
  }

  static Future<void> delete(int id) => _c.call('Source.Delete', [id]);

  static Future<void> deleteBatch(List<int> ids) =>
      _c.call('Source.DeleteBatch', [ids]);

  static Future<void> setEnabled(int id, bool enabled) =>
      _c.call('Source.SetEnabled', [id, enabled]);

  static Future<void> setEnabledBatch(List<int> ids, bool enabled) =>
      _c.call('Source.SetEnabledBatch', [ids, enabled]);

  // ── 分组维护 ────────────────────────────────────────────

  static Future<void> addToGroup(List<int> ids, String group) =>
      _c.call('Source.AddToGroup', [ids, group]);

  static Future<void> removeFromGroup(List<int> ids, String group) =>
      _c.call('Source.RemoveFromGroup', [ids, group]);

  static Future<void> renameGroup(String oldName, String newName) =>
      _c.call('Source.RenameGroup', [oldName, newName]);

  static Future<void> deleteGroup(String name) =>
      _c.call('Source.DeleteGroup', [name]);

  // ── 导入 ────────────────────────────────────────────────

  /// 导入书源 JSON 文本。
  ///
  /// core 的形参是 `[]byte`，JSON 传输时 Go 侧按 base64 解码，
  /// 所以这里必须先把文本 base64 一遍，否则会得到「非法字符」错误。
  static Future<Map<String, dynamic>> importText(
    String text, {
    bool overwrite = true,
  }) async {
    final encoded = base64Encode(utf8.encode(text));
    final data = await _c.call('Source.Import', [encoded, overwrite]);
    return _jsonMap(data);
  }

  static Future<Map<String, dynamic>> importFromUrl(
    String url, {
    bool overwrite = true,
  }) async {
    final data = await _c.call('Source.ImportFromURL', [url, overwrite]);
    return _jsonMap(data);
  }

  // ── 校验 / 调试 ─────────────────────────────────────────

  /// 校验书源规则。
  ///
  /// 四个开关全关时只做本地静态校验（不联网）；任一打开都会真发请求，
  /// 且请求链路是「搜索 → 详情 → 目录 → 正文」的累进形式。
  static Future<List<Map<String, dynamic>>> validate(
    List<int> ids, {
    bool search = false,
    bool info = false,
    bool toc = false,
    bool content = false,
    String keyword = '',
  }) {
    return _c.callList('Source.Validate', [
      ids,
      {
        'Search': search,
        'Info': info,
        'TOC': toc,
        'Content': content,
        'Keyword': keyword,
      },
    ]);
  }

  /// 用指定书源真实搜索一次，用于调试页的「搜索实测」。
  static Future<List<Map<String, dynamic>>> search(
    int id,
    String keyword, {
    int page = 1,
  }) {
    return _c.callList('Source.Search', [id, keyword, page]);
  }

  /// 当前是否有调试会话在跑（core 的 SourceDebug 只暴露了 Running）。
  static Future<Map<String, dynamic>> debugRunning() async {
    final data = await _c.call('SourceDebug.Running');
    return _jsonMap(data);
  }

  static Map<String, dynamic> _jsonMap(dynamic data) {
    if (data is Map) return data.cast<String, dynamic>();
    return <String, dynamic>{};
  }
}
