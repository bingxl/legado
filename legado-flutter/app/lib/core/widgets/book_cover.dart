import 'package:flutter/material.dart';

import '../image_url.dart';

/// 书籍封面。
///
/// 书源的 `coverUrl` 可能是绝对地址、协议相对地址，也可能根本没解析出来；
/// 因此这里统一做三件事：能请求就显示网络图，加载中/失败都回落到首字色块，
/// 且外框尺寸由调用方给定——列表滚动时不会因为图片尺寸变化而跳动。
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.name,
    this.url,
    this.width,
    this.height,
    this.radius = 6,
    this.fontSize = 16,
    this.placeholderColor,
    this.textColor,
  });

  /// 书名，用于兜底色块里的首字与无障碍描述。
  final String name;

  /// 封面地址（core 的 `cover` 字段）。
  final String? url;

  final double? width;
  final double? height;
  final double radius;
  final double fontSize;
  final Color? placeholderColor;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = _LetterCover(
      name: name,
      fontSize: fontSize,
      color: placeholderColor ?? scheme.primaryContainer,
      textColor: textColor ?? scheme.onPrimaryContainer,
    );
    final src = normalizeImageUrl(url);

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: src == null
            ? fallback
            : Image.network(
                src,
                // 防盗链 CDN（超星等）必须带 Referer，否则 403 落到兜底图。
                headers: imageHeaders(src),
                fit: BoxFit.cover,
                width: width,
                height: height,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                semanticLabel: name.isEmpty ? '封面' : '$name 封面',
                // 加载完成前显示兜底图：比一片透明更像「正在加载封面」，
                // 也不会让列表里出现高度为 0 的空洞。
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) return child;
                  return fallback;
                },
                errorBuilder: (context, error, stackTrace) => fallback,
              ),
      ),
    );
  }
}

/// 首字色块。没有封面、封面加载中、封面加载失败都落到这里。
class _LetterCover extends StatelessWidget {
  const _LetterCover({
    required this.name,
    required this.fontSize,
    required this.color,
    required this.textColor,
  });

  final String name;
  final double fontSize;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: Center(
        child: Text(
          name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
          maxLines: 1,
          style: TextStyle(
            fontSize: fontSize,
            color: textColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
