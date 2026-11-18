/// 控制面方法常量。
///
/// 全量方法表由 `legado schema -o schema.json` 导出（128 个），
/// 这里只列 UI 骨架当前用到的；各 feature 可自带常量，但**不要**在本文件追加
/// （它是共享区，并行开发时容易冲突）。
class Api {
  Api._();

  // 系统
  static const systemInfo = 'System.Info';
  static const systemMethods = 'System.Methods';

  // 书架 / 阅读
  static const shelfListGroups = 'Shelf.ListGroups';
  static const shelfListBooks = 'Shelf.ListBooks';
  static const shelfGetBook = 'Shelf.GetBook';
  static const shelfPutOnShelf = 'Shelf.PutOnShelf';
  static const shelfDeleteBook = 'Shelf.DeleteBook';
  static const shelfMoveToGroup = 'Shelf.MoveToGroup';
  static const shelfSaveProgress = 'Shelf.SaveProgress';
  static const shelfGetProgress = 'Shelf.GetProgress';

  // 阅读器
  static const readerGetChapters = 'Reader.GetChapters';
  static const readerGetContent = 'Reader.GetContent';
  static const readerGetProgress = 'Reader.GetProgress';
  static const readerSaveProgress = 'Reader.SaveProgress';

  // 书源
  static const sourceList = 'Source.List';
  static const sourceGet = 'Source.Get';
  static const sourceSearch = 'Source.Search';
  static const sourceExploreKinds = 'Source.ExploreKinds';
  static const sourceExplore = 'Source.Explore';

  // 缓存
  static const cacheStats = 'Cache.Stats';

  // 朗读
  static const ttsSegment = 'Tts.Segment';
}
