import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';
import '../settings/settings_store.dart';
import 'reader_style.dart';

/// 阅读器与 core 配置之间的**唯一**适配层。
///
/// 为什么要单独一层：阅读器只关心「字号多少、背景什么颜色」，
/// 不该知道配置是存在 app_settings 里、键名叫 `reader.fontSize`、
/// 取值是字符串。把所有这类翻译收在这里，设置页改结构时只改这一个文件。
///
/// 反向依赖（设置页 → 阅读器）只有一处：背景预设的颜色定义在
/// [ReaderBackground] 里，设置页取它渲染色块。单向依赖不会成环。
class ReaderPrefs {
  ReaderPrefs._();

  /// 当前生效的排版参数。
  ///
  /// 直接从配置存储读，失败时返回默认样式——阅读器不能因为配置读不出来就打不开书。
  static ReaderStyle get style {
    try {
      final cfg = SettingsStore.instance.readerConfig;
      return ReaderStyle.fromPrefs(
        fontSize: cfg.fontSize,
        lineHeight: cfg.lineHeight,
        paragraphSpacing: cfg.paragraphSpacing,
        indentFirstLine: cfg.indentFirstLine,
        paddingHorizontal: cfg.paddingHorizontal,
        paddingVertical: cfg.paddingVertical,
        theme: cfg.theme,
        pageTurn: cfg.pageTurn,
        showPageNumber: cfg.showPageNumber,
        textJustify: cfg.textJustify,
      );
    } catch (_) {
      return const ReaderStyle();
    }
  }

  /// 退出阅读器时是否要询问「加入书架」。
  static bool get promptAddToShelf {
    try {
      return SettingsStore.instance.readerConfig.promptAddToShelf;
    } catch (_) {
      return false;
    }
  }

  /// 把阅读器里的临时调整写回 core。
  ///
  /// 阅读器菜单能改字号/背景/翻页方式，这些都是设置项；不写回的话
  /// 「退出重进又变回原样」，用户会以为菜单坏了。
  /// 失败静默：这是体验优化，不该打断阅读（写不进去下次改还是会生效）。
  static Future<void> persist(ReaderStyle style) async {
    try {
      for (final entry in style.toPrefsPatch().entries) {
        await SettingsStore.instance.setValue(entry.key, entry.value);
      }
    } catch (_) {
      // 忽略：见方法注释
    }
  }

  /// 查询这本书是否已在书架。查不到按「不在书架」处理。
  static Future<bool> inShelf(int bookId) async {
    if (bookId <= 0) return true; // 无有效 ID，别去打扰用户
    try {
      final book = await LegadoClient.instance.call(Api.shelfGetBook, [bookId]);
      if (book is Map) return book['inShelf'] == true;
      return true;
    } catch (_) {
      // 查不到（书被删了/试读快照过期）就不要拦人。
      return true;
    }
  }

  /// 加入书架。返回是否成功，失败时调用方决定要不要提示。
  static Future<bool> addToShelf(int bookId) async {
    if (bookId <= 0) return false;
    try {
      await LegadoClient.instance.call(Api.shelfPutOnShelf, [bookId]);
      return true;
    } catch (_) {
      return false;
    }
  }
}
