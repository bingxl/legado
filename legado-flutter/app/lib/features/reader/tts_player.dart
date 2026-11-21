import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 朗读播放器：把 `Tts.Segment` 的片段排队交给系统 TTS 引擎。
///
/// 为什么只是个薄封装：断句属于业务（core 已经算好 `paragraph/start/end`），
/// 播放是适配器。这里只做三件事——队列推进、暂停/跳句、语速。
///
/// 平台差异都收在这里：
/// - Windows 上 `pause()` 不被支持，回落成 `stop()`（继续时从当前句重读）；
/// - 完成回调在部分平台会重复触发，用 [_speaking] 标记去重；
/// - 系统没装中文语音时 `setLanguage` 会失败，回落到引擎默认语言而不是报错。
class TtsPlayer extends ChangeNotifier {
  TtsPlayer({this.onFinished});

  /// 全部片段读完时回调（面板用它自动翻页续读）。
  final Future<void> Function()? onFinished;

  final FlutterTts _tts = FlutterTts();

  List<Map<String, dynamic>> _segments = const [];
  int _index = -1;
  bool _playing = false;
  bool _speaking = false;
  bool _disposed = false;
  bool _initialized = false;
  double _rate = 0.5;

  List<Map<String, dynamic>> get segments => _segments;
  int get index => _index;
  bool get playing => _playing;
  double get rate => _rate;

  String get currentText {
    if (_index < 0 || _index >= _segments.length) return '';
    return '${_segments[_index]['text'] ?? ''}'.trim();
  }

  /// 初始化引擎并按当前语速设好参数。重复调用无副作用。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final available = await _tts.isLanguageAvailable('zh-CN');
      if (available == true) {
        await _tts.setLanguage('zh-CN');
      }
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.setSpeechRate(_rate);
    } on Object {
      // 引擎能力探测失败不影响 speak：多数平台会用自己的默认值。
    }
    _tts.setCompletionHandler(_handleDone);
    _tts.setCancelHandler(() {
      _speaking = false;
    });
    _tts.setErrorHandler((Object? _) {
      _speaking = false;
      _playing = false;
      _safeNotify();
    });
  }

  /// 换一批片段（翻页后调用）。会停止当前朗读但保留语速。
  void load(List<Map<String, dynamic>> segments, {int startIndex = -1}) {
    _segments = segments;
    _index = segments.isEmpty
        ? -1
        : (startIndex < 0 ? 0 : startIndex.clamp(0, segments.length - 1));
    _safeNotify();
  }

  Future<void> play() async {
    if (_segments.isEmpty) return;
    await init();
    if (_index < 0) _index = 0;
    _playing = true;
    _safeNotify();
    await _speakCurrent();
  }

  Future<void> pause() async {
    _playing = false;
    _speaking = false;
    try {
      await _tts.pause();
    } on Object {
      // Windows 没有 pause：停止后由 resume() 从当前句重读。
      await _tts.stop();
    }
    _safeNotify();
  }

  Future<void> stop() async {
    _playing = false;
    _speaking = false;
    try {
      await _tts.stop();
    } on Object {
      // 引擎没起来时 stop 也可能抛，忽略即可。
    }
    _safeNotify();
  }

  /// 从指定片段开始读。
  Future<void> seek(int index) async {
    if (_segments.isEmpty) return;
    _index = index.clamp(0, _segments.length - 1);
    _playing = true;
    _safeNotify();
    await init();
    await _speakCurrent();
  }

  Future<void> next() async {
    if (_index + 1 >= _segments.length) {
      await stop();
      return;
    }
    await seek(_index + 1);
  }

  Future<void> prev() async {
    if (_index <= 0) {
      await seek(0);
      return;
    }
    await seek(_index - 1);
  }

  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.2, 1.0);
    try {
      await _tts.setSpeechRate(_rate);
    } on Object {
      // 不支持动态变速的平台，下一句仍是旧语速，但不该让 UI 报错。
    }
    _safeNotify();
  }

  Future<void> _speakCurrent() async {
    if (_index < 0 || _index >= _segments.length) return;
    final text = currentText;
    if (text.isEmpty) {
      // 空片段直接跳过，避免整条队列卡在一个没有文字的段上。
      _advanceInternal();
      return;
    }
    _speaking = true;
    try {
      await _tts.speak(text);
    } on Object {
      _speaking = false;
      _playing = false;
      _safeNotify();
    }
  }

  void _handleDone() {
    // 被打断（stop/pause/切页）时引擎也会回调，不能当成"读完"。
    if (!_speaking || !_playing || _disposed) return;
    _speaking = false;
    _advanceInternal();
  }

  void _advanceInternal() {
    if (_index + 1 < _segments.length) {
      _index++;
      _safeNotify();
      unawaited(_speakCurrent());
      return;
    }
    _playing = false;
    _safeNotify();
    final callback = onFinished;
    if (callback != null) unawaited(callback());
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_tts.stop().catchError((Object _) => null));
    super.dispose();
  }
}
