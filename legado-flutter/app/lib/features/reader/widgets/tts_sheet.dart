import 'dart:async';

import 'package:flutter/material.dart';

import '../reader_controller.dart';
import '../tts_player.dart';

/// 朗读面板。
///
/// 分段（`Tts.Segment`）在 core 侧算，播放交给 [TtsPlayer]（系统 TTS 引擎）。
/// 面板负责三件事：把当前页的片段列出来、点哪句读哪句、读完整页按需自动翻页。
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

class _TtsSheet extends StatefulWidget {
  const _TtsSheet({required this.controller});

  final ReaderController controller;

  @override
  State<_TtsSheet> createState() => _TtsSheetState();
}

class _TtsSheetState extends State<_TtsSheet> {
  late final TtsPlayer _player = TtsPlayer(onFinished: _handleFinished);
  final ScrollController _scroll = ScrollController();

  List<Map<String, dynamic>> _segments = const [];
  bool _loading = true;
  Object? _error;

  /// 一页读完自动翻下一页。
  bool _autoPage = true;

  /// 防止 onFinished → 翻页 → load → play 期间用户又点了一次播放。
  bool _advancing = false;

  @override
  void initState() {
    super.initState();
    _player.addListener(_onPlayerChanged);
    unawaited(_loadSegments(autoPlay: false));
  }

  @override
  void dispose() {
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
    } else {
      await _player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    return SizedBox(
      height: size.height * 0.62,
      child: Column(
        children: [
          _header(scheme),
          const Divider(height: 0.6),
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
                      Icons.graphic_eq,
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
              Icon(Icons.speed, size: 16, color: scheme.outline),
              SizedBox(
                width: 108,
                child: Slider(
                  value: _player.rate,
                  min: 0.2,
                  max: 1.0,
                  divisions: 8,
                  label: '${(_player.rate * 10).round() / 10}x',
                  onChanged: (value) => _player.setRate(value),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Switch(
                value: _autoPage,
                onChanged: (value) => setState(() => _autoPage = value),
              ),
              const SizedBox(width: 4),
              Text('读完整页自动翻页', style: TextStyle(fontSize: 12)),
              const Spacer(),
              Text(
                '${(_player.rate * 10).round() / 10}x',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
