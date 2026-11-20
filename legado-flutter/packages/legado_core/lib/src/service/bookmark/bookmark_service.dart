import '../../domain/domain.dart';
import '../../kernel/errors.dart';
import '../../store/store.dart';

/// 读取「这本书现在读到哪一章」。
///
/// 定义在服务层而不是 import shelf service：书签和流水只需要一个章节号，
/// 把整个书架服务拖进来会形成 `bookmark → shelf → ...` 的耦合环。
/// 装配层用 `ShelfModule.instance` 写一行适配器注入。
abstract class ProgressReader {
  int currentChapterIndex(int bookId);
}

/// 书签域。
class BookmarkService {
  BookmarkService(this._daos, {ProgressReader? progress}) : _progress = progress;

  final StoreDaos _daos;
  final ProgressReader? _progress;

  static const int defaultListLimit = 200;
  static const int maxListLimit = 1000;

  /// 新增书签。
  ///
  /// `chapterIndex < 0` 表示「当前位置」：阅读器不必先查一次进度再回传，
  /// 少一次往返也就少一个竞态窗口。
  BookmarkItem add(
    int bookId,
    int chapterIndex,
    String chapterTitle,
    int chapterPos,
    String content,
    String note,
  ) {
    if (bookId <= 0) {
      throw const LegadoException(ErrorCode.invalid, '缺少书籍 ID');
    }
    final resolved = _resolveChapter(bookId, chapterIndex);
    final item = BookmarkItem(
      bookId: bookId,
      chapterIndex: resolved,
      chapterTitle: chapterTitle,
      chapterPos: chapterPos,
      content: content,
      note: note,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    item.id = _daos.bookmarkItem.insert(item);
    // 回读 created_at 而不是用刚才的 now：值与后续 List 排序同一基准。
    return _daos.bookmarkItem.get(item.id)!;
  }

  /// [bookId] 为 0 表示全部；按创建时间倒序。
  List<Map<String, Object?>> list(int bookId, int limit) {
    if (bookId < 0) {
      throw const LegadoException(ErrorCode.invalid, '书籍 ID 不能为负');
    }
    final safe = limit <= 0
        ? defaultListLimit
        : (limit > maxListLimit ? maxListLimit : limit);
    return [for (final item in _daos.bookmarkItem.list(bookId, safe)) item.toJson()];
  }

  void remove(int id) {
    if (id <= 0) {
      throw const LegadoException(ErrorCode.invalid, '缺少书签 ID');
    }
    if (!_daos.bookmarkItem.remove(id)) {
      throw LegadoException(ErrorCode.notFound, '书签不存在: $id');
    }
  }

  void updateNote(int id, String note) {
    if (id <= 0) {
      throw const LegadoException(ErrorCode.invalid, '缺少书签 ID');
    }
    if (!_daos.bookmarkItem.updateNote(id, note)) {
      throw LegadoException(ErrorCode.notFound, '书签不存在: $id');
    }
  }

  int count(int bookId) {
    if (bookId <= 0) {
      throw const LegadoException(ErrorCode.invalid, '缺少书籍 ID');
    }
    return _daos.bookmarkItem.count(bookId);
  }

  int _resolveChapter(int bookId, int chapterIndex) {
    if (chapterIndex >= 0) return chapterIndex;
    final reader = _progress;
    if (reader == null) return 0;
    final index = reader.currentChapterIndex(bookId);
    return index < 0 ? 0 : index;
  }
}

/// 阅读记录域：每次换章留一条痕迹，供统计与历史页使用。
class RecordService {
  RecordService(this._daos, {ProgressReader? progress}) : _progress = progress;

  final StoreDaos _daos;
  final ProgressReader? _progress;

  static const int defaultListLimit = 200;
  static const int maxListLimit = 1000;

  /// 追加一条阅读记录，返回落库后的记录（供测试与事件回执）。
  ///
  /// 契约里返回类型是 `void`，模块层丢弃这个返回值即可。
  RecordItem append(
    int bookId,
    String bookName,
    int chapterIndex,
    String chapterTitle,
  ) {
    if (bookId <= 0) {
      throw const LegadoException(ErrorCode.invalid, '缺少书籍 ID');
    }
    final resolved = _resolveChapter(bookId, chapterIndex);
    return _daos.recordItem.append(bookId, bookName, resolved, chapterTitle);
  }

  List<Map<String, Object?>> list(int offset, int limit) {
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit <= 0
        ? defaultListLimit
        : (limit > maxListLimit ? maxListLimit : limit);
    return [
      for (final item in _daos.recordItem.list(safeOffset, safeLimit)) item.toJson()
    ];
  }

  /// 返回删除条数；`beforeDays <= 0` 全部清空。
  int clear(int beforeDays) => _daos.recordItem.clear(beforeDays);

  Map<String, Object?> stats() => _daos.recordItem.stats().toJson();

  int _resolveChapter(int bookId, int chapterIndex) {
    if (chapterIndex >= 0) return chapterIndex;
    final reader = _progress;
    if (reader == null) return 0;
    final index = reader.currentChapterIndex(bookId);
    return index < 0 ? 0 : index;
  }
}
