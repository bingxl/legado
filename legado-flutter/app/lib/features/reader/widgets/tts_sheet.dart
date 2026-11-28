import 'dart:async';

import 'package:flutter/material.dart';

import '../reader_controller.dart';
import '../../settings/settings_store.dart';
import '../tts_player.dart';

/// 朗读面板。
///
/// 分段（`Tts.Segment`）在 core 侧算，播放交给 [TtsPlayer]（系统 TTS 引擎）。
/// 面板负责四件事：把当前页的片段列出来、点哪句读哪句、读完整页按需自动翻页，
/// 以及在引擎不可用时**把原因说清楚**——系统 TTS 失效时只是不出声，
/// 不显式提示的话用户只会以为「朗读坏了」。
Future<void> showTtsSheet(BuildContext context, ReaderController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _TtsSheet(controller: controller),
  );
}

/// 片段行高固定：用 `itemExtent` 才能靠「序号 × 行高」精确滚到当前句。
const double _rowExtent = 88;

/// 语速/音调/自动翻页都落到设置里，退出重进不再回到默认值。
const String _keySpeed = 'reader.ttsSpeed';
const String _keyPitch = 'reader.ttsPitch';
const String _keyAutoPage = 'reader.ttsAutoPage';

class _TtsSheet extends StatefulWidget {
  const _TtsSheet({required this.controller});

  final ReaderController controller;

  @override
  State<_TtsSheet> createState() => _TtsSheetState();
}

class _TtsSheetState extends State<_TtsSheet> with WidgetsBindingObserver {
  late final double _initialSpeed = _readDouble(_keySpeed, 1.0);
  late final double _initialPitch = _readDouble(_keyPitch, 1.0);
  late final TtsPlayer _player = TtsPlayer(
    onFinished: _handleFinished,
    speed: _initialSpeed,
    pitch: _initialPitch,
  );
  final ScrollController _scroll = ScrollController();

  List<Map<String, dynamic>> _segments = const [];
  bool _loading = true;
  Object? _error;

  /// 一页读完自动翻下一页。
  bool _autoPage = _readBool(_keyAutoPage, true);

  /// 防止 onFinished → 翻页 → load → play 期间用户又点了一次播放。
  bool _advancing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player.addListener(_onPlayerChanged);
    unawaited(_loadSegments(autoPlay: false));
    // 打开面板就开始探测引擎：等用户点播放才发现「没装中文语音」已经太晚。
    unawaited(_player.init());
  }

  /// 退到后台就停止朗读。
  ///
  /// 系统 TTS 的音频不跟随应用生命周期：不主动停，锁屏后它还会一直念下去，
  /// 而用户手里没有任何控件能关掉（原版靠前台服务 + 通知栏解决，这里还没做）。
  /// 宁可不支持后台朗读，也不能出现「停不下来」的幽灵播报。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (_player.playing) unawaited(_player.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player.removeListener(_onPlayerChanged);
    _player.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    setState(() {});
    _scrollToCurrent();
  }

  /// 滚到当前句所在行（行高固定，直接算偏移，不依赖 ensureVisible 的可见性）。
  void _scrollToCurrent() {
    final index = _player.index;
    if (index < 0 || !_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final viewport = _scroll.position.viewportDimension;
      final target = index * _rowExtent - viewport / 2 + _rowExtent / 2;
      final max = _scroll.position.maxScrollExtent;
      _scroll.animateTo(
        target.clamp(0.0, max <= 0 ? 0.0 : max),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _loadSegments({required bool autoPlay}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final segments = await widget.controller.segmentCurrentPage();
      if (!mounted) return;
      setState(() {
        _segments = segments;
        _loading = false;
      });
      _player.load(segments);
      if (autoPlay && segments.isNotEmpty) await _player.play();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 一页读完：自动翻页并续读；位置没变说明已经是全书最后一页。
  Future<void> _handleFinished() async {
    if (!_autoPage || _advancing) return;
    _advancing = true;
    try {
      final beforeChapter = widget.controller.chapterIndex;
      final beforePage = widget.controller.pageIndex;
      await widget.controller.turnPage(1);
      if (!mounted) return;
      final moved =
          widget.controller.chapterIndex != beforeChapter ||
          widget.controller.pageIndex != beforePage;
      if (!moved) {
        _toast('已经是最后一页了');
        return;
      }
      await _loadSegments(autoPlay: true);
    } finally {
      _advancing = false;
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _togglePlay() async {
    if (_player.playing) {
      await _player.pause();
      return;
    }
    await _player.play();
    // 引擎不可用时 play() 不会出声，把原因再抛一次，别让用户盯着静止的界面。
    final error = _player.error;
    if (!mounted || error == null || _player.playing) return;
    _toast(error);
  }

  void _setSpeed(double value) {
    unawaited(_player.setSpeed(value));
    _persist(_keySpeed, value.toStringAsFixed(1));
  }

  void _setPitch(double value) {
    unawaited(_player.setPitch(value));
    _persist(_keyPitch, value.toStringAsFixed(1));
  }

  void _setAutoPage(bool value) {
    setState(() => _autoPage = value);
    _persist(_keyAutoPage, value ? 'true' : 'false');
  }

  /// 写设置失败不该打断朗读：本地值仍然对本次会话生效。
  void _persist(String key, String value) {
    unawaited(
      SettingsStore.instance.setValue(key, value).catchError((Object _) {}),
    );
  }

  /// 引擎选择：系统里可能装了多个（例如小爱 + 第三方），让用户自己挑。
  Future<void> _pickEngine() async {
    final engines = _player.engines;
    if (engines.length < 2) return;
    final current = _player.engineId;
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择语音引擎'),
        children: [
          for (final engine in engines)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(engine),
              child: Row(
                children: [
                  Icon(
                    engine == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(engine)),
                ],
              ),
            ),
        ],
      ),
    );
    if (!mounted || picked == null || picked == current) return;
    await _player.setEngine(picked);
    if (!mounted) return;
    final error = _player.error;
    if (error != null) _toast(error);
  }

  static double _readDouble(String key, double fallback) {
    final raw = SettingsStore.instance.values[key];
    final value = double.tryParse(raw ?? '');
    return value ?? fallback;
  }

  static bool _readBool(String key, bool fallback) {
    final raw = SettingsStore.instance.values[key];
    if (raw == null) return fallback;
    return raw == 'true';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    return SizedBox(
      height: size.height * 0.68,
      child: Column(
        children: [
          _header(scheme),
          const Divider(height: 0.6),
          if (_player.error != null) _errorBanner(scheme, _player.error!),
          Expanded(child: _body(scheme)),
          _controls(scheme),
        ],
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    final total = _segments.length;
    final current = _player.index >= 0 ? _player.index + 1 : 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Row(
        children: [
          const Icon(Icons.record_voice_over_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('朗读', style: Theme.of(context).textTheme.titleMedium),
                Text(
                  total == 0
                      ? widget.controller.chapterTitle
                      : '${widget.controller.chapterTitle} · 第 ${current.clamp(1, total)}/$total 句',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// 引擎状态条：这行的作用是把「为什么没声音」直接写在面板上。
  Widget _engineBar(ColorScheme scheme) {
    final ok = _player.status == TtsEngineStatus.ready;
    final color = ok ? scheme.outline : scheme.error;
    final canPick = _player.engines.length > 1;
    return InkWell(
      onTap: canPick ? _pickEngine : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
        child: Row(
          children: [
            Icon(
              ok ? Icons.volume_up_outlined : Icons.volume_off_outlined,
              size: 14,
              color: color,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _player.statusText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: color),
              ),
            ),
            if (canPick)
              Text(
                '切换引擎',
                style: TextStyle(fontSize: 11, color: scheme.primary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _errorBanner(ColorScheme scheme, String message) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 11, color: scheme.onErrorContainer),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(_player.init(force: true)),
            child: const Text('重试', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('分段失败：$_error', textAlign: TextAlign.center),
        ),
      );
    }
    if (_segments.isEmpty) {
      return Center(
        child: Text(
          '本页没有可朗读的文字',
          style: TextStyle(color: scheme.outline),
        ),
      );
    }
    final current = _player.index;
    return ListView.builder(
      controller: _scroll,
      itemExtent: _rowExtent,
      itemCount: _segments.length,
      itemBuilder: (context, index) {
        final segment = _segments[index];
        final text = '${segment['text'] ?? ''}'.trim();
        final paragraph = segment['paragraph'];
        final active = index == current;
        return InkWell(
          onTap: () => _player.seek(index),
          child: Container(
            color: active
                ? scheme.primaryContainer.withValues(alpha: 0.45)
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 26,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                        color: active ? scheme.primary : scheme.outline,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (paragraph != null)
                        Text(
                          '第 $paragraph 段',
                          style: TextStyle(fontSize: 10, color: scheme.outline),
                        ),
                    ],
                  ),
                ),
                if (active && _player.playing)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 2),
                    child: Icon(
                      _player.speaking ? Icons.graphic_eq : Icons.hourglass_top,
                      size: 16,
                      color: scheme.primary,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _controls(ColorScheme scheme) {
    final enabled = _segments.isNotEmpty && !_loading;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _engineBar(scheme),
          Row(
            children: [
              IconButton(
                tooltip: '上一句',
                onPressed: enabled ? _player.prev : null,
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton.filled(
                tooltip: _player.playing ? '暂停' : '朗读',
                onPressed: enabled ? _togglePlay : null,
                icon: Icon(_player.playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                tooltip: '下一句',
                onPressed: enabled ? _player.next : null,
                icon: const Icon(Icons.skip_next),
              ),
              IconButton(
                tooltip: '停止',
                onPressed: enabled ? _player.stop : null,
                icon: const Icon(Icons.stop),
              ),
              const Spacer(),
              Text(
                '${_player.speed.toStringAsFixed(1)}x',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          ),
          _sliderRow(
            scheme,
            label: '语速',
            value: _player.speed,
            min: 0.4,
            max: 2.0,
            onChanged: _setSpeed,
          ),
          _sliderRow(
            scheme,
            label: '音调',
            value: _player.pitch,
            min: 0.5,
            max: 2.0,
            onChanged: _setPitch,
          ),
          Row(
            children: [
              Switch(value: _autoPage, onChanged: _setAutoPage),
              const SizedBox(width: 4),
              const Text('读完整页自动翻页', style: TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  /// 语速/音调共用的一行：左边固定标签，右边滑块，避免两个滑块挤成两整行。
  Widget _sliderRow(
    ColorScheme scheme, {
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 32,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / 0.1).round(),
            label: value.toStringAsFixed(1),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            value.toStringAsFixed(1),
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
        ),
      ],
    );
  }
}
