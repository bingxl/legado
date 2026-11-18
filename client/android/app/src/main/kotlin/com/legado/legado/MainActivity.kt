package com.legado.legado

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // core 通过 gomobile AAR 跑在进程内，数据目录用应用私有 filesDir。
        LegadoChannel.register(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext.filesDir.absolutePath,
        )
    }
}
