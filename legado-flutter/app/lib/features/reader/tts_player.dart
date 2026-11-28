import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 朗读引擎的可用状态。
///
/// 它存在的唯一理由是「让静音有解释」：系统 TTS 失败时不会抛异常，
/// 只是不出声——不把状态显式建模出来，UI 就只能显示一个假的「正在播放」。
enum TtsEngineStatus {
  /// 还没探测过。
  unknown,

  /// 引擎可用，中文语音也在。
  ready,

  /// 引擎可用，但没有中文语音（英文书仍能读）。
  noChineseVoice,

  /// 系统里没有任何 TTS 引擎，或引擎服务绑定不上（Android 11+ 包可见性）。
  noEngine,

  /// 探测过程本身抛错。
  failed,
}

/// 界面语速（倍速，1.0 为正常）→ flutter_tts 的语速。
///
/// flutter_tts 为了让各平台一致，把 Android 的 1.0（正常）映射成 0.5，
/// 也就是说它的取值区间 `0.0~1.0` 实际对应 `0x~2x`。我们对外用倍速，
/// 转换只在这一个函数里做，UI 不必知道这层偏移。
double flutterSpeechRate(double speed) => (speed * 0.5).clamp(0.2, 1.0);

/// 一次朗读多久没动静就判定「引擎没响应」。
///
/// 按中文约 4~5 字/秒估时，再留 6 秒给引擎启动/合成；语速越慢允许等越久。
/// 这个兜底是必需的：flutter_tts 在引擎未绑定（`speak` 返回 false）时会把调用
/// 重新排队而不是报错，`speak()` 的 Future 可能永远不完成。
Duration ttsWatchdogTimeout(String text, double speed) {
  final chars = text.runes.length;
  final safeSpeed = speed <= 0 ? 1.0 : speed;
  final estimate = (chars * 260 / safeSpeed).round();
  final ms = 6000 + estimate;
  return Duration(milliseconds: ms.clamp(8000, 60000));
}

/// 朗读播放器：把 `Tts.Segment` 的片段排队交给系统 TTS 引擎。
///
/// 为什么只是个薄封装：断句属于业务（core 已经算好 `paragraph/start/end`），
/// 播放是适配器。这里只做四件事——队列推进、暂停/跳句、语速音调、故障可见化。
///
/// 平台差异都收在这里：
/// - Windows 上 `pause()` 不被支持，回落成 `stop()`（继续时从当前句重读）；
/// - 完成回调在部分平台会重复触发，用 [_active] 标记去重；
/// - 系统没装中文语音时 `setLanguage` 会失败，回落到引擎默认语言而不是报错；
/// - Android 11+ 若清单里缺 `TTS_SERVICE` 的 `<queries>`，引擎绑定不上，
///   `speak()` 会一直重排、既不报错也不出声——靠 [watchdog] 兜底。
class TtsPlayer extends ChangeNotifier {
  TtsPlayer({
    this.onFinished,
    FlutterTts? engine,
    double speed = 1.0,
    double pitch = 1.0,
  }) : _tts = engine ?? FlutterTts(),
       _speed = speed.clamp(0.4, 2.0),
       _pitch = pitch.clamp(0.5, 2.0);

  /// 全部片段读完时回调（面板用它自动翻页续读）。
  final Future<void> Function()? onFinished;

  final FlutterTts _tts;

  List<Map<String, dynamic>> _segments = const [];
  int _index = -1;
  bool _playing = false;

  /// 当前这一句已经从引擎「开始发声」（收到了 start 回调）。
  bool _speaking = false;

  /// 已发出 speak、还没收到 done/cancel/error。用它而不是 [_speaking] 去重：
  /// 个别引擎不保证发 start，只发 done。
  bool _active = false;

  bool _disposed = false;
  bool _handlersReady = false;

  /// 进行中的探测；[init] 复用同一个 Future，避免并发探测把语言设回默认。
  Future<void>? _initFuture;
  int _initSeq = 0;

  /// 每次开始新一句自增，用来丢弃上一次尝试的迟到回调。
  int _generation = 0;

  double _speed;
  double _pitch;

  TtsEngineStatus _status = TtsEngineStatus.unknown;
  String? _error;
  String? _engineId;
  List<String> _engines = const [];

  /// 语言探测命中的标签（`zh-CN` / `zh` / …），null 表示没有中文语音。
  String? _language;
  Timer? _watchdog;

  List<Map<String, dynamic>> get segments => _segments;
  int get index => _index;
  bool get playing => _playing;

  /// 引擎真的开始出声了（UI 用它决定显示「朗读中」还是「准备中」）。
  bool get speaking => _playing && _speaking;
  double get speed => _speed;
  double get pitch => _pitch;
  TtsEngineStatus get status => _status;

  /// 最近一次失败原因；成功开始朗读时清空。
  String? get error => _error;

  /// 当前使用的引擎包名（Android）。仅用于诊断展示。
  String? get engineId => _engineId;

  /// 系统里可选的引擎（Android 上才有内容）。
  List<String> get engines => _engines;

  bool get hasChineseVoice => _language != null;

  String get currentText {
    if (_index < 0 || _index >= _segments.length) return '';
    return '${_segments[_index]['text'] ?? ''}'.trim();
  }

  /// 给用户看的一句话状态，UI 直接显示，不必自己拼。
  String get statusText {
    switch (_status) {
      case TtsEngineStatus.unknown:
        return '正在检测语音引擎…';
      case TtsEngineStatus.ready:
        final id = _engineId;
        return id == null ? '系统语音引擎就绪' : '$id · 中文语音可用';
      case TtsEngineStatus.noChineseVoice:
        return '引擎可用，但没有中文语音（可读英文）';
      case TtsEngineStatus.noEngine:
        return '没有可用的系统语音引擎';
      case TtsEngineStatus.failed:
        return '语音引擎检测失败';
    }
  }

  /// 初始化引擎并按当前语速/音调设好参数。
  ///
  /// [force] 用于切换引擎后重新探测；普通调用重复执行无副作用。
  Future<void> init({bool force = false}) {
    final existing = _initFuture;
    // 复用同一次探测：面板打开和点播放会各调一次，不能并发跑两遍——
    // 后一次若在 setLanguage 之前就返回，speak 会落到引擎的默认语言上。
    if (!force && existing != null) return existing;
    final seq = ++_initSeq;
    final future = _runInit(seq);
    _initFuture = future;
    return future;
  }

  Future<void> _runInit(int seq) async {
    _registerHandlers();
    _status = TtsEngineStatus.unknown;
    _notify();
    try {
      final engines = await _tts.getEngines;
      if (seq != _initSeq || _disposed) return;
      _engines = <String>[
        for (final item in (engines is List ? engines : const []))
          if ('$item'.isNotEmpty) '$item',
      ];
      if (_engines.isEmpty) {
        // 空列表 = 服务端解析不到任何引擎服务。Android 11+ 最常见的原因是
        // 清单缺 TTS_SERVICE 的 <queries>，其次是设备真的没装引擎。
        _status = TtsEngineStatus.noEngine;
        _error =
            '系统没有可用的语音引擎：请先在「系统设置 → 无障碍 → 文字转语音」里'
            '安装并启用一个引擎（部分设备需重启应用后生效）';
        _notify();
        return;
      }
      _engineId = await _resolveEngineId();
      _language = await _probeChinese();
      await _applyVoiceParams();
      if (seq != _initSeq || _disposed) return;
      if (_language == null) {
        _status = TtsEngineStatus.noChineseVoice;
        // 不设 _error：英文书仍能朗读，只是中文会念不出来。
      } else {
        _status = TtsEngineStatus.ready;
        _error = null;
      }
    } on Object catch (e) {
      if (seq != _initSeq || _disposed) return;
      _status = TtsEngineStatus.failed;
      _error = '语音引擎检测失败：$e';
    }
    _notify();
  }

  /// 换一批片段（翻页后调用）。会停止当前朗读但保留语速。
  void load(List<Map<String, dynamic>> segments, {int startIndex = -1}) {
    _segments = segments;
    _index = segments.isEmpty
        ? -1
        : (startIndex < 0 ? 0 : startIndex.clamp(0, segments.length - 1));
    _notify();
  }

  Future<void> play() async {
    if (_segments.isEmpty) return;
    await init();
    if (_segments.isEmpty) return;
    if (_index < 0) _index = 0;
    if (_status == TtsEngineStatus.noEngine) {
      // 没有引擎就别伪装成「正在播放」，直接把原因抛给界面。
      _playing = false;
      _notify();
      return;
    }
    _playing = true;
    _error = null;
    _notify();
    await _speakCurrent();
  }

  Future<void> pause() async {
    _playing = false;
    _speaking = false;
    _active = false;
    _generation++;
    _watchdog?.cancel();
    try {
      await _tts.pause();
    } on Object {
      // Windows 没有 pause：停止后由 play() 从当前句重读。
      try {
        await _tts.stop();
      } on Object {
        // 引擎没起来时 stop 也可能抛，忽略即可。
      }
    }
    _notify();
  }

  Future<void> stop() async {
    _playing = false;
    _speaking = false;
    _active = false;
    _generation++;
    _watchdog?.cancel();
    try {
      await _tts.stop();
    } on Object {
      // 引擎没起来时 stop 也可能抛，忽略即可。
    }
    _notify();
  }

  /// 从指定片段开始读。
  Future<void> seek(int index) async {
    if (_segments.isEmpty) return;
    _index = index.clamp(0, _segments.length - 1);
    _playing = true;
    _error = null;
    _notify();
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

  /// 设置倍速（1.0 为正常语速）。正在读的这一句不变，下一句生效。
  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.4, 2.0);
    try {
      await _tts.setSpeechRate(flutterSpeechRate(_speed));
    } on Object {
      // 不支持动态变速的平台，下一句仍是旧语速，但不该让 UI 报错。
    }
    _notify();
  }

  Future<void> setPitch(double pitch) async {
    _pitch = pitch.clamp(0.5, 2.0);
    try {
      await _tts.setPitch(_pitch);
    } on Object {
      // 同上：音调只是增强项。
    }
    _notify();
  }

  /// 切换到指定引擎（包名）。切换后重新探测中文语音，正在读的会从当前句续上。
  Future<void> setEngine(String engineId) async {
    if (engineId.isEmpty || engineId == _engineId) return;
    try {
      await _tts.setEngine(engineId);
    } on Object catch (e) {
      _error = '切换语音引擎失败：$e';
      _notify();
      return;
    }
    _engineId = engineId;
    await init(force: true);
    if (_playing) await _speakCurrent();
  }

  // ---------------------------------------------------------------- 内部实现

  void _registerHandlers() {
    if (_handlersReady) return;
    _handlersReady = true;
    _tts.setStartHandler(_handleStart);
    _tts.setCompletionHandler(_handleDone);
    _tts.setCancelHandler(_handleCancel);
    _tts.setErrorHandler(_handleError);
  }

  /// 引擎包名：优先取系统默认引擎，拿不到就退回第一个可选引擎。
  Future<String?> _resolveEngineId() async {
    try {
      final id = await _tts.getDefaultEngine;
      if (id is String && id.isNotEmpty) return id;
    } on Object {
      // 部分平台没有 getDefaultEngine，不算失败。
    }
    return _engines.isEmpty ? null : _engines.first;
  }

  /// 依次探测中文标签，返回第一个可用的。
  ///
  /// 顺序有讲究：`zh-CN` 是大陆普通话，`zh` 是只声明语族的引擎（部分第三方
  /// 引擎只认它），`zh-Hans-CN` 是脚本细分标签。全都不可用才算「没有中文语音」。
  Future<String?> _probeChinese() async {
    const candidates = <String>['zh-CN', 'zh', 'zh-Hans-CN'];
    for (final tag in candidates) {
      try {
        final available = await _tts.isLanguageAvailable(tag);
        if (available == true) {
          final applied = await _tts.setLanguage(tag);
          // Android 的 setLanguage 返回 1/0，iOS 返回 1；0 表示引擎拒绝。
          if (applied == 0) continue;
          return tag;
        }
      } on Object {
        // 单个标签探测失败继续试下一个。
      }
    }
    return null;
  }

  Future<void> _applyVoiceParams() async {
    try {
      await _tts.setVolume(1.0);
      await _tts.setPitch(_pitch);
      await _tts.setSpeechRate(flutterSpeechRate(_speed));
    } on Object {
      // 引擎能力不足时用自己的默认值，不影响能否出声。
    }
  }

  Future<void> _speakCurrent() async {
    if (_index < 0 || _index >= _segments.length) return;
    final text = currentText;
    if (text.isEmpty) {
      // 空片段直接跳过，避免整条队列卡在一个没有文字的段上。
      _advanceInternal();
      return;
    }
    final generation = ++_generation;
    _active = true;
    _speaking = false;
    _error = null;
    _notify();
    _startWatchdog(text, generation);
    try {
      // 不要 await：引擎未绑定时插件会把调用重新排队，Future 可能永不完成。
      final pending = _tts.speak(text);
      unawaited(
        pending.then((value) {
          if (_disposed || generation != _generation) return;
          // Android 成功返回 1；0 表示「被拒」——多半是上一句还在说或引擎没绑定。
          if (value == 0) {
            _fail('语音引擎拒绝了这次朗读（可能仍在播放上一句），请稍后重试');
          }
        }).catchError((Object e) {
          if (_disposed || generation != _generation) return;
          _fail('朗读失败：$e');
        }),
      );
    } on Object catch (e) {
      _fail('朗读失败：$e');
    }
  }

  /// 发出 speak 后若既没有 start 也没有 done，就判定引擎没响应。
  void _startWatchdog(String text, int generation) {
    _watchdog?.cancel();
    _watchdog = Timer(ttsWatchdogTimeout(text, _speed), () {
      if (_disposed || generation != _generation) return;
      if (!_playing || !_active || _speaking) return;
      _fail(
        '语音引擎 ${ttsWatchdogTimeout(text, _speed).inSeconds} 秒内没有开始朗读：'
        '请检查系统「文字转语音」是否已启用可用引擎',
      );
    });
  }

  void _handleStart() {
    if (_disposed) return;
    _watchdog?.cancel();
    _speaking = true;
    _active = true;
    _notify();
  }

  void _handleDone() {
    // 被打断（stop/pause/切页）时引擎也会回调，不能当成「读完」。
    if (_disposed || !_playing || !_active) return;
    _active = false;
    _speaking = false;
    _watchdog?.cancel();
    _advanceInternal();
  }

  void _handleCancel() {
    if (_disposed) return;
    _active = false;
    _speaking = false;
    _watchdog?.cancel();
    _notify();
  }

  void _handleError(Object? message) {
    if (_disposed) return;
    _fail('语音引擎报错：${message ?? '未知错误'}');
  }

  /// 统一的失败出口：停掉引擎、复位状态、把原因留给界面。
  void _fail(String message) {
    _generation++;
    _watchdog?.cancel();
    _active = false;
    _speaking = false;
    _playing = false;
    _error = message;
    unawaited(_tts.stop().catchError((Object _) => null));
    _notify();
  }

  void _advanceInternal() {
    if (_index + 1 < _segments.length) {
      _index++;
      _notify();
      unawaited(_speakCurrent());
      return;
    }
    _playing = false;
    _notify();
    final callback = onFinished;
    if (callback != null) unawaited(callback());
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _watchdog?.cancel();
    unawaited(_tts.stop().catchError((Object _) => null));
    super.dispose();
  }
}
