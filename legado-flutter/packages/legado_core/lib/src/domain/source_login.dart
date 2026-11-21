import 'row_utils.dart';

/// 书源登录态补充信息。
///
/// Cookie 走 `cookies` 表 / `cookies.json`（网络层自管），这张表只存
/// Cookie 装不下的东西：用户**手动粘贴的请求头原文**（含 UA/Referer/Cookie）
/// 与登录脚本的回执。
///
/// 为什么需要它：没有内嵌浏览器的宿主（桌面 / CLI）没法完成「打开登录页、
/// 用户点登录、从 WebView 取 cookie」这一套，只能让用户从浏览器复制请求头
/// 粘回来。原文必须留下来，否则下次 `Header` 就还不出用户填了什么。
class SourceLoginRecord {
  SourceLoginRecord({
    this.bookSourceUrl = '',
    this.header = '',
    this.info = '',
    this.updatedAt = 0,
  });

  static const String tableSourceLogins = 'source_login';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `source_login` (
  `bookSourceUrl` TEXT NOT NULL,
  `header` TEXT NOT NULL DEFAULT '',
  `info` TEXT NOT NULL DEFAULT '',
  `updatedAt` INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(`bookSourceUrl`)
)''';

  /// 书源地址（与 `book_sources.bookSourceUrl` 对应，不用 rowid：
  /// 导入导出书源后 rowid 会变，地址不变）。
  String bookSourceUrl;

  /// 粘贴的请求头原文。
  String header;

  /// 登录回执（账号名、脚本输出摘要等），只用于展示。
  String info;

  int updatedAt;

  factory SourceLoginRecord.fromRow(Map<String, Object?> row) => SourceLoginRecord(
        bookSourceUrl: asString(row['bookSourceUrl']),
        header: asString(row['header']),
        info: asString(row['info']),
        updatedAt: asInt(row['updatedAt']),
      );

  Map<String, Object?> toRow() => <String, Object?>{
        'bookSourceUrl': bookSourceUrl,
        'header': header,
        'info': info,
        'updatedAt': updatedAt,
      };
}
