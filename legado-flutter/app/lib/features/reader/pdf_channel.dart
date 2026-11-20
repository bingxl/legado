/// 平台 PDF 渲染通道。
///
/// 内核只解析页数/章节，真正的逐页位图由 Android 侧 `PdfRenderer` 产出
/// （见 MainActivity.kt）。这里把 MethodChannel 的原始调用收成三个方法，
/// 让阅读页不直接碰平台细节，桌面/无通道环境下也能给出可读错误。
library;

import 'package:flutter/services.dart';

/// 本 feature 私有的 core 方法名（共享 Api 文件不允许追加）。
const pdfGetLocalFile = 'Reader.GetLocalFile';
const pdfSyncOutline = 'Reader.SyncOutline';

class PdfChannel {
  PdfChannel._();

  static const MethodChannel _channel = MethodChannel('flutter.legado/pdf');

  static Future<int> pageCount(String path) async {
    final value = await _channel.invokeMethod<int>('pageCount', {'path': path});
    return value ?? 0;
  }

  /// 渲染指定页为 PNG 字节。
  ///
  /// [width] 是目标像素宽（按设备像素比算），高度由原页宽高比决定；
  /// 原生层会 clamp 到 [1, 2560]，避免异常参数把内存打满。
  static Future<Uint8List> renderPage(
    String path,
    int page,
    int width,
  ) async {
    final value = await _channel.invokeMethod<Uint8List>(
      'renderPage',
      <String, Object?>{'path': path, 'page': page, 'width': width},
    );
    if (value == null || value.isEmpty) {
      throw const PdfRenderException('渲染结果为空');
    }
    return value;
  }

  /// 关闭文档，释放 ParcelFileDescriptor。
  static Future<void> close(String path) async {
    try {
      await _channel.invokeMethod<void>('close', {'path': path});
    } on PlatformException {
      // 退出时释放失败不影响用户，忽略。
    }
  }
}

class PdfRenderException implements Exception {
  const PdfRenderException(this.message);

  final String message;

  @override
  String toString() => message;
}
