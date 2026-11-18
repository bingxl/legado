import 'package:flutter/material.dart';

import '../settings_models.dart';

/// 单个 Schema 条目的渲染入口：按 kind 分发到对应控件。
///
/// 未知 kind 不报错也不藏起来——降级成「标题 + 当前值」的只读行，
/// 这样后端先上 Schema、前端稍后补控件时页面仍然完整可用。
class SettingsControl extends StatelessWidget {
  const SettingsControl({
    super.key,
    required this.item,
    required this.raw,
    required this.display,
    required this.onChanged,
  });

  final SettingsItem item;

  /// Values 里的原始字符串。
  final String raw;

  /// 已格式化好的展示文本（由 store.displayValue 提供，保证各页一致）。
  final String display;

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    switch (item.kind) {
      case SettingsKind.toggle:
        return SwitchListTile.adaptive(
          value: settingsBool(
            raw,
            item.defaultValue is bool && item.defaultValue == true,
          ),
          onChanged: (value) => onChanged(value ? 'true' : 'false'),
          title: Text(item.title),
          subtitle: _desc(context),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        );
      case SettingsKind.slider:
        // max 缺失（0 表示无上限）时滑块没有意义，退化成只读行。
        if (!item.hasRange) {
          return _ReadOnlyTile(item: item, display: display, note: '该项没有可调区间');
        }
        return _SliderControl(
          item: item,
          raw: raw,
          display: display,
          onChanged: onChanged,
        );
      case SettingsKind.select:
        return _SelectControl(item: item, raw: raw, onChanged: onChanged);
      case SettingsKind.number:
        return _TextControl(
          item: item,
          raw: raw,
          numeric: true,
          onChanged: onChanged,
        );
      case SettingsKind.text:
        return _TextControl(item: item, raw: raw, onChanged: onChanged);
      case SettingsKind.unknown:
        return _ReadOnlyTile(item: item, display: display, note: '暂不支持编辑');
    }
  }

  Widget? _desc(BuildContext context) {
    final desc = item.desc;
    if (desc == null) return null;
    return Text(
      desc,
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

/// 标题 + 说明的统一排版：标题一行，desc 小字灰色一行（没有就不占位）。
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.item, this.trailing});

  final SettingsItem item;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final desc = item.desc;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: const TextStyle(fontSize: 14)),
              if (desc != null) ...[
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 12),
          trailing!,
        ],
      ],
    );
  }
}

class _ValueBadge extends StatelessWidget {
  const _ValueBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
      ),
    );
  }
}

/// 滑块。value 必须落在 [min,max] 内，否则 Slider 会直接断言失败；
/// 脏数据（负数/超界/非数字）统一夹回区间。
class _SliderControl extends StatefulWidget {
  const _SliderControl({
    required this.item,
    required this.raw,
    required this.display,
    required this.onChanged,
  });

  final SettingsItem item;
  final String raw;
  final String display;
  final ValueChanged<String> onChanged;

  @override
  State<_SliderControl> createState() => _SliderControlState();
}

class _SliderControlState extends State<_SliderControl> {
  late double _value = _read();

  double _read() {
    final item = widget.item;
    final fallback = item.defaultValue is num
        ? (item.defaultValue as num).toDouble()
        : item.min;
    final parsed = settingsDouble(widget.raw, fallback);
    return parsed.clamp(item.min, item.max).toDouble();
  }

  @override
  void didUpdateWidget(covariant _SliderControl old) {
    super.didUpdateWidget(old);
    // 外部改了值（重置/回滚）时跟随，但拖拽中不要被自己的回传打断。
    if (widget.raw != old.raw && !_dragging) {
      setState(() => _value = _read());
    }
  }

  bool _dragging = false;

  /// 让整数项回传 "26"、小数项回传 "1.8"，而不是 1.8000000000000003。
  String _wire(double value) {
    final step = widget.item.step;
    final snapped = step <= 0 ? value : (value / step).round() * step;
    return settingsNumberText(double.parse(snapped.toStringAsFixed(4)));
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // 步长过细时 division 会非常大，交给 Slider 连续取值更稳。
    final divisions = ((item.max - item.min) / item.step).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TitleBlock(
            item: item,
            trailing: _ValueBadge(text: widget.display),
          ),
          Slider(
            value: _value,
            min: item.min,
            max: item.max,
            divisions: divisions > 100 || divisions <= 0 ? null : divisions,
            onChanged: (value) {
              _dragging = true;
              setState(() => _value = value);
            },
            onChangeEnd: (value) {
              _dragging = false;
              setState(() => _value = value);
              widget.onChanged(_wire(value));
            },
          ),
        ],
      ),
    );
  }
}

class _SelectControl extends StatelessWidget {
  const _SelectControl({
    required this.item,
    required this.raw,
    required this.onChanged,
  });

  final SettingsItem item;
  final String raw;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = item.options;
    // 服务端值不在选项里（Schema 演进）时补一项，避免 Dropdown 断言失败。
    final hasCurrent = options.any((option) => option.value == raw);
    return ListTile(
      title: Text(item.title),
      subtitle: item.desc == null
          ? null
          : Text(
              item.desc!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: hasCurrent ? raw : null,
          hint: Text(hasCurrent ? raw : raw.isEmpty ? '未设置' : raw),
          isDense: true,
          focusColor: Colors.transparent,
          items: <DropdownMenuItem<String>>[
            for (final option in options)
              DropdownMenuItem<String>(
                value: option.value,
                child: Text(option.label),
              ),
          ],
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ),
    );
  }
}

/// number/text：提交式编辑，避免每敲一个字符就发一次请求。
class _TextControl extends StatefulWidget {
  const _TextControl({
    required this.item,
    required this.raw,
    required this.onChanged,
    this.numeric = false,
  });

  final SettingsItem item;
  final String raw;
  final ValueChanged<String> onChanged;
  final bool numeric;

  @override
  State<_TextControl> createState() => _TextControlState();
}

class _TextControlState extends State<_TextControl> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.raw,
  );

  @override
  void didUpdateWidget(covariant _TextControl old) {
    super.didUpdateWidget(old);
    if (widget.raw != old.raw && widget.raw != _controller.text) {
      _controller.text = widget.raw;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final text = _controller.text.trim();
    if (text == widget.raw) return;
    widget.onChanged(text);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TitleBlock(item: widget.item),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            keyboardType: widget.numeric
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.text,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _commit(),
            onTapOutside: (_) {
              FocusScope.of(context).unfocus();
              _commit();
            },
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyTile extends StatelessWidget {
  const _ReadOnlyTile({
    required this.item,
    required this.display,
    required this.note,
  });

  final SettingsItem item;
  final String display;
  final String note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(item.title),
      subtitle: Text(
        item.desc == null ? note : '${item.desc} · $note',
        style: TextStyle(fontSize: 12, color: scheme.outline),
      ),
      trailing: Text(display, style: TextStyle(color: scheme.outline)),
    );
  }
}
