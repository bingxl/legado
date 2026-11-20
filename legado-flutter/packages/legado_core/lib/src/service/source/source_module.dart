import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import '../service_args.dart';
import 'source_service.dart';

/// 书源域的本地管理部分（搜索/发现/试读在 SourceFetchModule）。
class SourceModule extends CoreModule {
  SourceService? _service;

  @override
  String get name => 'source';

  @override
  List<String> get dependsOn => const ['store'];

  SourceService get service {
    final service = _service;
    if (service == null) throw StateError('source 模块尚未 register');
    return service;
  }

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    if (store == null) throw StateError('source 依赖 store');
    final service = SourceService(store.daos);
    _service = service;

    // ---- 查询与增删改 ----
    registry.method(
      'Source.List',
      (args) async => [
        for (final view in service.list(asText(arg(args, 0)))) view.toJson(),
      ],
      params: const ['group string'],
      doc: '列表不含 raw',
    );
    registry.method(
      'Source.Get',
      (args) async => service.get(asInt(arg(args, 0))).toJson(),
      params: const ['id int'],
      doc: '含 raw 全文',
    );
    registry.method(
      'Source.Save',
      (args) async => service
          .save(
            asInt(arg(args, 0)),
            asText(arg(args, 1)),
            asText(arg(args, 2)),
            asText(arg(args, 3)),
            asText(arg(args, 4)),
            asText(arg(args, 5)),
            asBool(arg(args, 6)),
            asInt(arg(args, 7)),
          )
          .toJson(),
      params: const [
        'id int',
        'name string',
        'group string',
        'url string',
        'comment string',
        'raw string',
        'enabled bool',
        'order int',
      ],
      doc: '8 个位置参数；id=0 新增',
    );
    registry.method('Source.Delete', (args) async {
      service.delete(asInt(arg(args, 0)));
      return null;
    }, params: const ['id int']);
    registry.method('Source.SetEnabled', (args) async {
      service.setEnabled(asInt(arg(args, 0)), asBool(arg(args, 1)));
      return null;
    }, params: const ['id int', 'enabled bool']);

    // ---- 导入导出与校验 ----
    registry.method(
      'Source.Import',
      (args) async => (await service.importBase64(
        asText(arg(args, 0)),
        asBool(arg(args, 1)),
      )).toJson(),
      params: const ['dataBase64 string', 'overwrite bool'],
    );
    registry.method(
      'Source.ImportFromURL',
      (args) async => (await service.importFromURL(
        asText(arg(args, 0)),
        asBool(arg(args, 1)),
      )).toJson(),
      params: const ['rawURL string', 'overwrite bool'],
    );
    registry.method(
      'Source.Export',
      (args) async => service.export(_ids(arg(args, 0))),
      params: const ['ids int[]'],
      doc: '返回 base64 的 Legado JSON 数组',
    );
    registry.method(
      'Source.Validate',
      (args) async => [
        for (final result in service.validate(
          _ids(arg(args, 0)),
          asMap(arg(args, 1)),
        ))
          result.toJson(),
      ],
      params: const ['ids int[]', 'items Map'],
      doc: '结构校验，不联网',
    );

    // ---- 分组 ----
    registry.method(
      'Source.ListGroups',
      (args) async => [
        for (final group in service.listGroups()) group.toJson(),
      ],
    );
    registry.method(
      'Source.AddGroupToNoGroup',
      (args) async => service.addGroupToNoGroup(asText(arg(args, 0))),
      params: const ['group string'],
      doc: '返回受影响条数',
    );
    registry.method(
      'Source.RenameGroup',
      (args) async =>
          service.renameGroup(asText(arg(args, 0)), asText(arg(args, 1))),
      params: const ['oldName string', 'newName string'],
    );
    registry.method(
      'Source.DeleteGroup',
      (args) async => service.deleteGroup(asText(arg(args, 0))),
      params: const ['name string'],
    );
    registry.method('Source.AddToGroup', (args) async {
      service.addToGroup(_ids(arg(args, 0)), asText(arg(args, 1)));
      return null;
    }, params: const ['ids int[]', 'group string']);
    registry.method('Source.RemoveFromGroup', (args) async {
      service.removeFromGroup(_ids(arg(args, 0)), asText(arg(args, 1)));
      return null;
    }, params: const ['ids int[]', 'group string']);

    // ---- 批量与排序 ----
    registry.method('Source.SetEnabledBatch', (args) async {
      service.setEnabledBatch(_ids(arg(args, 0)), asBool(arg(args, 1)));
      return null;
    }, params: const ['ids int[]', 'enabled bool']);
    registry.method('Source.SetEnabledExploreBatch', (args) async {
      service.setEnabledExploreBatch(_ids(arg(args, 0)), asBool(arg(args, 1)));
      return null;
    }, params: const ['ids int[]', 'enabled bool']);
    registry.method('Source.DeleteBatch', (args) async {
      service.deleteBatch(_ids(arg(args, 0)));
      return null;
    }, params: const ['ids int[]']);
    registry.method('Source.MoveTop', (args) async {
      service.moveTop(_ids(arg(args, 0)));
      return null;
    }, params: const ['ids int[]']);
    registry.method('Source.MoveBottom', (args) async {
      service.moveBottom(_ids(arg(args, 0)));
      return null;
    }, params: const ['ids int[]']);
    registry.method('Source.Reorder', (args) async {
      service.reorder(_ids(arg(args, 0)));
      return null;
    }, params: const ['ids int[]']);

    // ---- 变量 / Cookie ----
    registry.method(
      'Source.GetVariable',
      (args) async => service.getVariable(asInt(arg(args, 0))),
      params: const ['id int'],
    );
    registry.method('Source.SetVariable', (args) async {
      service.setVariable(asInt(arg(args, 0)), asText(arg(args, 1)));
      return null;
    }, params: const ['id int', 'variable string']);
    registry.method('Source.ClearCookie', (args) async {
      service.clearCookie(asInt(arg(args, 0)));
      return null;
    }, params: const ['id int']);

    // ---- 订阅源 ----
    registry.method(
      'Source.ListSubscriptions',
      (args) async => service.listSubscriptions(),
    );
    registry.method(
      'Source.GetSubscription',
      (args) async => service.getSubscription(asInt(arg(args, 0))),
      params: const ['id int'],
    );
    registry.method(
      'Source.SaveSubscription',
      (args) async => service.saveSubscription(
        asInt(arg(args, 0)),
        asText(arg(args, 1)),
        asText(arg(args, 2)),
        asBool(arg(args, 3)),
        asInt(arg(args, 4)),
      ),
      params: const [
        'id int',
        'name string',
        'url string',
        'enabled bool',
        'order int',
      ],
    );
    registry.method('Source.DeleteSubscription', (args) async {
      service.deleteSubscription(asInt(arg(args, 0)));
      return null;
    }, params: const ['id int']);
    registry.method('Source.SetSubscriptionEnabled', (args) async {
      service.setSubscriptionEnabled(asInt(arg(args, 0)), asBool(arg(args, 1)));
      return null;
    }, params: const ['id int', 'enabled bool']);
    registry.method(
      'Source.SyncSubscription',
      (args) async =>
          (await service.syncSubscription(asInt(arg(args, 0)))).toJson(),
      params: const ['id int'],
    );
    registry.method(
      'Source.SyncAllSubscriptions',
      (args) async => [
        for (final result in await service.syncAllSubscriptions())
          result.toJson(),
      ],
    );
  }

  @override
  Future<void> close() async {
    final service = _service;
    _service = null;
    service?.close();
  }
}

List<int> _ids(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) return const [];
  return [for (final item in raw) asInt(item)];
}
