import '../../kernel/errors.dart';
import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import 'tts_segmenter.dart';

/// 朗读域模块。
///
/// 目前只有分段一个能力（不依赖数据库、不依赖网络），但它已经能支撑
/// 「朗读预览」与「跨页续读定位」两件事：UI 拿片段列表就能高亮当前句，
/// 也能把 `(paragraph, start)` 落盘后精确跳回。
///
/// 后续接引擎（系统朗读 / HTTP TTS）时，只需要新增 `Tts.*` 方法，
/// 分段这一层不用动 —— 断点是业务，播放是适配器。
class TtsModule extends CoreModule {
  @override
  String get name => 'tts';

  @override
  void register(Registry registry, LegadoContext ctx) {
    registry.method(
      'Tts.Segment',
      (args) async {
        final text = _arg(args, 0);
        final maxRunes = _arg(args, 1);
        return <Object?>[
          for (final segment in splitTtsSegments(
            _asText(text),
            _asInt(maxRunes),
          ))
            segment.toJson(),
        ];
      },
      params: const ['text string', 'maxRunes int'],
      doc: '把正文切成朗读片段；maxRunes<=0 时按 120 字',
    );
  }
}

Object? _arg(List<Object?> args, int index) =>
    index < args.length ? args[index] : null;

/// 缺省按空串处理：Go 版对缺参数就是零值语义，这里保持一致，
/// 让「少传一个参数」不会变成一次 EXPLICIT 的类型错误。
String _asText(Object? raw) {
  if (raw == null) return '';
  if (raw is String) return raw;
  if (raw is num || raw is bool) return '$raw';
  throw LegadoException(
    ErrorCode.invalid,
    'text 需要字符串，收到 ${raw.runtimeType}',
  );
}

/// JSON 里的数字可能是 `int` 也可能是 `double`（`120` 与 `120.0`）。
/// 后者取整，不做四舍五入的错误假设：朗读上限是「字」不是「字节」。
int _asInt(Object? raw) {
  if (raw == null) return 0;
  if (raw is int) return raw;
  if (raw is double) return raw.isFinite ? raw.toInt() : 0;
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  throw LegadoException(
    ErrorCode.invalid,
    'maxRunes 需要整数，收到 ${raw.runtimeType}',
  );
}
