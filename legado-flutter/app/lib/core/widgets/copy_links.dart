import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/api.dart';
import '../bridge/legado_client.dart';

/// 一条可复制的地址（书籍 / 书源 / 封面 / 本章）。
///
/// 单独抽出来是为了让「哪些地址该出现在菜单里」变成纯函数（[bookCopyLinks]），
/// 好写单测，也避免详情页和三个阅读器各拼一份、各漏一个。
class CopyLink {
  const CopyLink(this.label, this.value);

  /// 菜单里显示的名字，如「书籍地址」。
  final String label;

  /// 真正复制到剪贴板的内容。
  final String value;

  @override
  String toString() => '$label: $value';
}

/// 按可用性拼出地址列表，顺序即菜单顺序。
///
/// - `bookUrl`：网络书是书源里的详情页地址；本地书是文件绝对路径（也有用）。
/// - `origin`：本地书的 origin 是 `local` 这种标记，不是地址，直接剔掉。
/// - `coverUrl`：多半是防盗链直链，复制出来方便在别的设备上试。
/// - `chapterUrl`：只有阅读器传。
List<CopyLink> bookCopyLinks({
  String bookUrl = '',
  String origin = '',
  String coverUrl = '',
  String chapterUrl = '',
}) {
  final links = <CopyLink>[];
  void add(String label, String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) links.add(CopyLink(label, trimmed));
  }

  add('书籍地址', bookUrl);
  // 本地书的 origin 是 BookType.localTag（`local`），没有 `://` 的都不当地址。
  if (origin.contains('://')) add('书源地址', origin);
  add('封面地址', coverUrl);
  add('本章地址', chapterUrl);
  return links;
}

/// 复制并提示。菜单项点击后都走这里，保证文案一致。
///
/// [notify] 给页面自定义提示（详情页有自己的 `_toast`，会先 hide 掉上一条）；
/// 不传就退回 `ScaffoldMessenger`。
Future<void> copyLink(
  BuildContext context,
  CopyLink link, {
  void Function(String message)? notify,
}) async {
  final value = link.value.trim();
  void show(String message) {
    if (notify != null) {
      notify(message);
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  if (value.isEmpty) {
    show('没有可复制的${link.label}');
    return;
  }
  await Clipboard.setData(ClipboardData(text: value));
  show('${link.label}已复制');
}

/// 底部面板列出可复制地址（阅读器用：那里没有 AppBar 放菜单）。
///
/// [bookUrl] 为空时按 [bookId] 从 core 取一次书籍详情——漫画/PDF 阅读器
/// 只拿得到 bookId，不该为此在页面里再存一份书源数据。
Future<void> showCopyLinkSheet(
  BuildContext context, {
  required int bookId,
  String bookUrl = '',
  String chapterUrl = '',
  String title = '复制地址',
}) async {
  var resolvedBookUrl = bookUrl;
  var origin = '';
  var coverUrl = '';
  if (resolvedBookUrl.isEmpty && bookId > 0) {
    try {
      final detail = await LegadoClient.instance.call(Api.shelfGetBook, [bookId]);
      if (detail is Map) {
        resolvedBookUrl = '${detail['bookUrl'] ?? ''}';
        origin = '${detail['origin'] ?? ''}';
        coverUrl = '${detail['cover'] ?? ''}';
      }
    } on Object {
      // 取不到详情就只给「本章地址」，不阻断面板。
    }
  }
  if (!context.mounted) return;

  final links = bookCopyLinks(
    bookUrl: resolvedBookUrl,
    origin: origin,
    coverUrl: coverUrl,
    chapterUrl: chapterUrl,
  );
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
          ),
          if (links.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Text('这本书没有可复制的地址'),
            )
          else
            for (final link in links)
              ListTile(
                leading: const Icon(Icons.link, size: 20),
                title: Text(link.label, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  link.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  copyLink(context, link);
                },
              ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
