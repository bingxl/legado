import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 手动缓存的章节范围。
///
/// [start]/[end] 是阅读页展示用的 1-based 章号（与 Kotlin 原版
/// `DialogDownloadChoiceBinding` 的输入框一致）；内核 `Cache.Start` 收 0-based，
/// 统一由 [indexes] 换算，别在各处再减一。
@immutable
class CacheRange {
  const CacheRange({required this.start, required this.end});

  final int start;
  final int end;

  int get count => end - start + 1;

  List<int> get indexes => [for (var i = start; i <= end; i++) i - 1];

  @override
  String toString() => 'CacheRange($start..$end)';
}

/// 阅读页「离线缓存」对话框。
///
/// 对应原版 `BaseReadBookActivity.showDownloadDialog()`：两个数字框输入起止章，
/// 默认「当前章 ~ 末章」。返回 null 表示用户取消或本书没有章节。
Future<CacheRange?> showCacheRangeDialog({
  required BuildContext context,
  required int currentChapter,
  required int totalChapters,
}) {
  if (totalChapters < 1) return Future.value(null);
  final current = currentChapter.clamp(1, totalChapters);
  return showDialog<CacheRange>(
    context: context,
    builder: (_) => _CacheRangeDialog(
      currentChapter: current,
      totalChapters: totalChapters,
    ),
  );
}

class _CacheRangeDialog extends StatefulWidget {
  const _CacheRangeDialog({
    required this.currentChapter,
    required this.totalChapters,
  });

  final int currentChapter;
  final int totalChapters;

  @override
  State<_CacheRangeDialog> createState() => _CacheRangeDialogState();
}

class _CacheRangeDialogState extends State<_CacheRangeDialog> {
  late final TextEditingController _start;
  late final TextEditingController _end;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start = TextEditingController(text: '${widget.currentChapter}');
    _end = TextEditingController(text: '${widget.totalChapters}');
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  int _parse(TextEditingController controller, int fallback) {
    final value = int.tryParse(controller.text.trim());
    if (value == null) return fallback;
    return value.clamp(1, widget.totalChapters);
  }

  void _confirm() {
    final start = _parse(_start, widget.currentChapter);
    final end = _parse(_end, widget.totalChapters);
    if (start > end) {
      setState(() => _error = '起始章不能大于结束章');
      return;
    }
    Navigator.of(context).pop(CacheRange(start: start, end: end));
  }

  @override
  Widget build(BuildContext context) {
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
    );
    return AlertDialog(
      title: const Text('离线缓存'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('选择要缓存的章节范围，默认从当前章缓存到本书结尾。'),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('章节', style: TextStyle(fontSize: 14)),
              const SizedBox(width: 8),
              SizedBox(
                width: 76,
                child: TextField(
                  controller: _start,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    border: inputBorder,
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                ),
              ),
              const SizedBox(width: 8),
              const Text('至', style: TextStyle(fontSize: 14)),
              const SizedBox(width: 8),
              SizedBox(
                width: 76,
                child: TextField(
                  controller: _end,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    border: inputBorder,
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '当前第 ${widget.currentChapter} 章 / 共 ${widget.totalChapters} 章',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(
              _error!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _confirm, child: const Text('开始缓存')),
      ],
    );
  }
}
