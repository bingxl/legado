import 'dart:io';

import 'package:flutter/material.dart';

import '../image_url.dart';

/// 按图片地址查本地缓存路径；返回 null 表示未缓存，交给网络。
typedef LocalImagePathResolver = String? Function(String url);

/// 阅读器里的图片：命中内核磁盘缓存时读本地文件，否则走网络（带防盗链头）。
///
/// 网络漫画章、正文插图和全屏看图三处都用这一个组件 —— 之前三处各自
/// `Image.network`，缓存图片补齐后会出现「正文插图读本地、看图页还是联网」
/// 这种半截行为。缓存路径由 `Reader.GetContent.imagePaths` 提供，未命中时
/// 传 null，行为与改动前完全一致。
class CachedReaderImage extends StatelessWidget {
  const CachedReaderImage({
    super.key,
    required this.url,
    this.localPath,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.high,
    this.cacheWidth,
    this.semanticLabel,
    this.frameBuilder,
    required this.errorBuilder,
  });

  final String url;

  /// 内核返回的已落盘图片绝对路径；null / 不存在时回落到网络。
  final String? localPath;

  final double? width;
  final double? height;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final int? cacheWidth;
  final String? semanticLabel;
  final ImageFrameBuilder? frameBuilder;
  final ImageErrorWidgetBuilder errorBuilder;

  @override
  Widget build(BuildContext context) {
    final path = localPath;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (file.existsSync()) {
        return Image.file(
          file,
          width: width,
          height: height,
          fit: fit,
          filterQuality: filterQuality,
          semanticLabel: semanticLabel,
          frameBuilder: frameBuilder,
          errorBuilder: errorBuilder,
          gaplessPlayback: true,
        );
      }
    }

    final src = normalizeImageUrl(url);
    if (src == null) {
      return errorBuilder(context, '无效图片地址: $url', StackTrace.empty);
    }
    return Image.network(
      src,
      // 图片 CDN 防盗链：不带 Referer 会 403（超星图片尤其明显）。
      headers: imageHeaders(src),
      width: width,
      height: height,
      fit: fit,
      filterQuality: filterQuality,
      cacheWidth: cacheWidth,
      semanticLabel: semanticLabel,
      frameBuilder: frameBuilder,
      errorBuilder: errorBuilder,
      gaplessPlayback: true,
    );
  }
}
