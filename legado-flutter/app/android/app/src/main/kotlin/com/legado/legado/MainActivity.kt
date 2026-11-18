package com.legado.legado

import io.flutter.embedding.android.FlutterActivity

/// 内核已经改成纯 Dart，Android 侧不再需要 MethodChannel 桥接任何 Go 代码。
/// 保留这个类是为了将来放平台能力（前台听书服务、通知、文件关联），
/// 目前它就是标准 FlutterActivity。
class MainActivity : FlutterActivity()
