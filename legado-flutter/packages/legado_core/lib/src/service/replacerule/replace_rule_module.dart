import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import '../service_args.dart';
import 'replace_rule_service.dart';

/// 替换净化域模块：7 个方法。
class ReplaceRuleModule extends CoreModule {
  @override
  String get name => 'replacerule';

  @override
  List<String> get dependsOn => const ['store'];

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    if (store == null) {
      throw StateError('replacerule 依赖 store');
    }
    final service = ReplaceRuleService(store.daos);

    registry.method(
      'ReplaceRule.List',
      (args) async => [for (final view in service.list()) view.toJson()],
    );

    registry.method(
      'ReplaceRule.Get',
      (args) async => service.get(asInt(arg(args, 0))).toJson(),
      params: const ['id int'],
    );

    registry.method(
      'ReplaceRule.Save',
      (args) async => service
          .save(
            asInt(arg(args, 0)),
            asText(arg(args, 1)),
            asText(arg(args, 2)),
            asText(arg(args, 3)),
            asBool(arg(args, 4)),
            asInt(arg(args, 5)),
          )
          .toJson(),
      params: const [
        'id int',
        'name string',
        'group string',
        'raw string',
        'enabled bool',
        'order int',
      ],
      doc: 'raw 是规则 JSON 数组文本；空串兜成 []',
    );

    registry.method(
      'ReplaceRule.Delete',
      (args) async {
        service.remove(asInt(arg(args, 0)));
        return null;
      },
      params: const ['id int'],
    );

    registry.method(
      'ReplaceRule.SetEnabled',
      (args) async {
        service.setEnabled(asInt(arg(args, 0)), asBool(arg(args, 1)));
        return null;
      },
      params: const ['id int', 'enabled bool'],
    );

    registry.method(
      'ReplaceRule.Import',
      (args) async => service
          .importBase64(
            asText(arg(args, 0)),
            overwrite: asBool(arg(args, 1)),
          )
          .toJson(),
      params: const ['dataBase64 string', 'overwrite bool'],
    );

    registry.method(
      'ReplaceRule.Export',
      (args) async {
        final raw = (arg(args, 0) as List?) ?? const <Object?>[];
        return service.exportBase64([for (final id in raw) asInt(id)]);
      },
      params: const ['ids int[]'],
      doc: 'ids 空导出全部；返回 base64 的 JSON 数组',
    );
  }
}
