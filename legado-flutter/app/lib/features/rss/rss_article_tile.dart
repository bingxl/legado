import 'package:flutter/material.dart';

import 'rss_api.dart';
import 'rss_text.dart';

/// 文章列表行：文章列表与收藏页共用。
///
/// 只用 dto 里已有的字段渲染；未读用左侧圆点 + 加粗标题表示，
/// 不做「点开后本地改色」之外的额外状态，避免与 core 的已读态打架。
class RssArticleTile extends StatelessWidget {
  const RssArticleTile({
    super.key,
    required this.article,
    required this.onTap,
    this.showSource = true,
  });

  final Map<String, dynamic> article;
  final VoidCallback onTap;

  /// 收藏页也可以显示来源；保留开关便于以后按场景收窄。
  final bool showSource;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = article['read'] != true;
    final title = '${article['title'] ?? ''}'.trim();
    final sourceName = '${article['sourceName'] ?? ''}'.trim();
    final time = RssText.formatTime(rssInt(article['pubDate']));
    final meta = [
      if (showSource && sourceName.isNotEmpty) sourceName,
      if (time.isNotEmpty) time,
    ].join(' · ');
    final preview = RssText.snippet(
      '${article['description'] ?? ''}'.trim().isNotEmpty
          ? '${article['description']}'
          : '${article['content'] ?? ''}',
    );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 10),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: unread ? scheme.primary : Colors.transparent,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? '（无标题）' : title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.35,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                      color: unread ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
                  if (preview.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: scheme.outline,
                      ),
                    ),
                  ],
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (article['favorite'] == true)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.star,
                              size: 12,
                              color: scheme.tertiary,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: scheme.outline),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
