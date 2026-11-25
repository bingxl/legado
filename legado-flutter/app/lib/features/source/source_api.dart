import 'dart:convert';

import '../../core/bridge/dto.dart';
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
    return asStringMap(data);
  }

  static Future<Map<String, dynamic>> importFromUrl(
    String url, {
    bool overwrite = true,
  }) async {
    final data = await _c.call('Source.ImportFromURL', [url, overwrite]);
    return asStringMap(data);
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

  /// 全源搜索（换源时找同名书的其它来源）。
  ///
  /// [scope] 沿用原版 `SearchScope` 编码：空=全部启用源、`名称::地址`=单源、
  /// `分组1,分组2`=多分组。必须显式传第三个参数 —— 只传两参时内核取默认值
  /// 虽然也是全源，但搜索页记住的范围（如「只在某分组换源」）会被静默丢掉。
  static Future<List<Map<String, dynamic>>> searchAll(
    String keyword, {
    int page = 1,
    String scope = '',
  }) {
    return _c.callList('Source.SearchAll', [keyword, page, scope]);
  }

  /// 当前是否有调试会话在跑。
  ///
  /// 注意：内核（`legado_core`）**没有**注册 `SourceDebug.*` 任何方法——
  /// 规则引擎的调试打点只在 Kotlin 原版里通过 lifecycle 事件暴露。这里曾按
  /// Go 版内核的契约写过 `SourceDebug.Running`，调用必然抛「未知方法」，
  /// 且没有调用方，已删除。调试页改用 `Source.Validate` 的一次性结果。

  // ── 登录 ────────────────────────────────────────────────

  /// 登录面板信息（登录方式、表单字段、是否已有 cookie、粘贴的请求头）。
  static Future<Map<String, dynamic>> loginProfile(int sourceId) async {
    final data = await _c.call('SourceLogin.Profile', [sourceId]);
    return asStringMap(data);
  }

  /// 登录。`kind=page` 时返回的 `openUrl` 需要用户自己去浏览器打开。
  static Future<Map<String, dynamic>> login(
    int sourceId,
    Map<String, String> form,
  ) async {
    final data = await _c.call('SourceLogin.Login', [sourceId, form]);
    return asStringMap(data);
  }

  /// 执行 `loginUi` 里的自定义按钮。
  static Future<Map<String, dynamic>> runLoginAction(
    int sourceId,
    String action,
    Map<String, String> form,
  ) async {
    final data = await _c.call('SourceLogin.RunAction', [
      sourceId,
      action,
      form,
    ]);
    return asStringMap(data);
  }

  /// 保存粘贴的请求头；空串表示清除。
  static Future<Map<String, dynamic>> saveLoginHeader(
    int sourceId,
    String header,
  ) async {
    final data = await _c.call('SourceLogin.SaveHeader', [sourceId, header]);
    return asStringMap(data);
  }

  /// 粘贴的请求头原文。
  static Future<String> loginHeader(int sourceId) async =>
      '${await _c.call('SourceLogin.Header', [sourceId])}';

  static Future<void> clearLogin(int sourceId, bool withForm) =>
      _c.call('SourceLogin.Clear', [sourceId, withForm]);

  /// 探测当前账号是否需要登录。
  static Future<Map<String, dynamic>> checkLogin(
    int sourceId,
    String probeUrl,
  ) async {
    final data = await _c.call('SourceLogin.Check', [sourceId, probeUrl]);
    return asStringMap(data);
  }

}
