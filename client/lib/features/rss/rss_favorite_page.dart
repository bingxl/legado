import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import 'rss_api.dart';
import 'rss_article_page.dart';
import 'rss_article_tile.dart';

/// 订阅收藏页（对应原版 `ui/rss/favorites/RssFavoritesActivity`）。
///
/// 收藏列表由 core 直接按发布时间倒序给出，Dart 侧不做二次排序与分页。
class RssFavoritePage extends StatefulWidget {
  const RssFavoritePage({super.key});

  @override
  State<RssFavoritePage> createState() => _RssFavoritePageState();
}

class _RssFavoritePageState extends State<RssFavoritePage> {
  List<Map<String, dynamic>> _articles = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await RssApi.listFavorites();
      if (!mounted) return;
      setState(() {
        _articles = list;
        _loading = false;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _open(Map<String, dynamic> article) async {
    final content = '${article['content'] ?? ''}'.trim().isNotEmpty
        ? '${article['content']}'
        : '${article['description'] ?? ''}';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RssArticlePage(
          articleId: rssInt(article['id']),
          title: '${article['title'] ?? ''}',
          content: content,
          link: '${article['link'] ?? ''}',
          favorite: article['favorite'] == true,
          pubDate: rssInt(article['pubDate']),
          sourceName: '${article['sourceName'] ?? ''}',
        ),
      ),
    );
    // 正文页里可能取消了收藏，回来必须重拉。
    if (!mounted) return;
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅收藏'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 36, color: scheme.outline),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _reload, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_articles.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 120),
            Icon(Icons.star_border, size: 36, color: scheme.outline),
            const SizedBox(height: 12),
            Center(
              child: Text(
                '还没有收藏的文章',
                style: TextStyle(color: scheme.outline),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                '在正文页点右上角的星标即可收藏',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _articles.length,
        separatorBuilder: (_, _) => const Divider(height: 0.6, indent: 16),
        itemBuilder: (_, i) {
          final article = _articles[i];
          return RssArticleTile(
            article: article,
            onTap: () => _open(article),
          );
        },
      ),
    );
  }
}
