import 'package:flutter/foundation.dart';

/// 书架数据变更广播。
///
/// 原版书架是 Room + Flow：`books` / `reading_progress` 表一变，书架列表的
/// LiveData 会自己重发。Flutter 侧是通过 RPC 读一次快照，没有这层观察者，
/// 所以**凡是改动书架数据的地方都要主动调一次 [changed]**，书架页收到后
/// 静默重拉一次列表。否则就会出现「加入/删除后要下拉刷新、甚至重启才同步」。
///
/// 已有的通知点：
/// - 详情页：加入书架、移出书架、编辑信息、刷新详情、换源
/// - 阅读器：退出时落进度、阅读完成提示里加入书架
/// - 书架页自身：删除、分组移动等（它自己会重载，通知只是为了让其它订阅者一致）
class ShelfEvents {
  ShelfEvents._();

  /// 书架数据可能已变化时 +1。书架页监听这个计数，值一变就重拉。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 通知书架数据已变更。
  static void changed() => revision.value++;
}
