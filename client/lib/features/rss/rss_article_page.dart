import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/bridge/legado_client.dart';
import 'rss_api.dart';
import 'rss_text.dart';

/// 订阅正文页（对应原版 `ui/rss/read/ReadRssActivity`）。
///
/// 正文由列表页随 dto 传进来：RSS 没有章节那样的独立数据面通道，
/// 单篇通常只有几十 KB，再发一次请求反而更慢。
///
/// 打开即标记已读；收藏是 toggle 语义（core 返回切换后的状态），
/// 因此本地必须记住当前状态，否则图标会与实际状态错位。
class RssArticlePage extends StatefulWidget {
  const RssArticlePage({
    super.key,
    required this.articleId,
    this.title,
    this.content,
    this.link,
    this.favorite = false,
    this.pubDate,
    this.sourceName,
  });

  final int articleId;
  final String? title;

  /// 正文原文（可能是 HTML，渲染前会压平成纯文本）。
  final String? content;
  final String? link;

  /// 进入时的收藏状态，用于图标初值。
  final bool favorite;

  /// 源站发布时间（Unix 秒），0 表示未知。
  final int? pubDate;
  final String? sourceName;

  @override
  State<RssArticlePage> createState() => _RssArticlePageState();
}

class _RssArticlePageState extends State<RssArticlePage> {
  /// 正文字号只做本地状态：不同端的舒适字号不同，先不落配置。
  static const double _minFontSize = 13;
  static const double _maxFontSize = 30;

  double _fontSize = 17;
  bool _favorite = false;
  bool _favoriteBusy = false;

  @override
  void initState() {
    super.initState();
    _favorite = widget.favorite;
    _markRead();
  }

  /// 已读是附带状态：core 离线时不影响正文阅读，失败静默。
  Future<void> _markRead() async {
    if (widget.articleId <= 0) return;
    try {
      await RssApi.markRead(widget.articleId, true);
    } catch (_) {
      // 忽略：下次打开或刷新列表时 core 会以库里的状态为准。
    }
  }

  Future<void> _toggleFavorite() async {
    if (_favoriteBusy || widget.articleId <= 0) return;
    setState(() => _favoriteBusy = true);
    try {
      final state = await RssApi.toggleFavorite(widget.articleId);
      if (!mounted) return;
      setState(() => _favorite = state);
      _toast(state ? '已收藏' : '已取消收藏');
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('${e.code}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  /// 没有 url_launcher：先复制链接，再提示用户到系统浏览器打开。
  Future<void> _copyLink({bool forBrowser = false}) async {
    final link = (widget.link ?? '').trim();
    if (link.isEmpty) {
      _toast('这篇文章没有原始链接');
      return;
    }
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    _toast(forBrowser ? '链接已复制，请粘贴到系统浏览器打开' : '链接已复制');
  }

  void _changeFontSize(double delta) {
    final next = (_fontSize + delta).clamp(_minFontSize, _maxFontSize);
    if (next == _fontSize) return;
    setState(() => _fontSize = next);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final body = RssText.stripHtml(widget.content);
    return Scaffold(
      appBar: AppBar(
        title: const Text('文章'),
        actions: [
          IconButton(
            tooltip: _favorite ? '取消收藏' : '收藏',
            onPressed: _favoriteBusy ? null : _toggleFavorite,
            icon: Icon(
              _favorite ? Icons.star : Icons.star_border,
              color: _favorite ? Colors.amber : null,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'copy') _copyLink();
              if (value == 'browser') _copyLink(forBrowser: true);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'copy', child: Text('复制链接')),
              PopupMenuItem(value: 'browser', child: Text('在浏览器打开')),
            ],
          ),
        ],
      ),
      body: body.isEmpty ? _emptyBody() : _articleBody(body),
      bottomNavigationBar: _fontBar(),
    );
  }

  Widget _articleBody(String body) {
    final scheme = Theme.of(context).colorScheme;
    final title = (widget.title ?? '').trim();
    final sourceName = (widget.sourceName ?? '').trim();
    final time = RssText.formatDateTime(widget.pubDate ?? 0);
    final meta = [
      if (sourceName.isNotEmpty) sourceName,
      if (time.isNotEmpty) time,
    ].join(' · ');

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title.isNotEmpty)
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 22,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  meta,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1),
              ),
              SelectableText(
                body,
                style: TextStyle(fontSize: _fontSize, height: 1.75),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyBody() {
    final scheme = Theme.of(context).colorScheme;
    final hasLink = (widget.link ?? '').trim().isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.article_outlined, size: 36, color: scheme.outline),
            const SizedBox(height: 12),
            const Text('这篇文章没有正文'),
            if (hasLink) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _copyLink,
                child: const Text('复制原文链接'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 字号工具条：加减都夹在 13~30，避免调成不可读的大小。
  Widget _fontBar() {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant, width: 0.6)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            IconButton(
              tooltip: '缩小字号',
              icon: const Icon(Icons.text_decrease),
              onPressed: _fontSize > _minFontSize
                  ? () => _changeFontSize(-1)
                  : null,
            ),
            SizedBox(
              width: 28,
              child: Text(
                '${_fontSize.round()}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
            IconButton(
              tooltip: '放大字号',
              icon: const Icon(Icons.text_increase),
              onPressed: _fontSize < _maxFontSize
                  ? () => _changeFontSize(1)
                  : null,
            ),
            const Spacer(),
            Text(
              '字号',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
