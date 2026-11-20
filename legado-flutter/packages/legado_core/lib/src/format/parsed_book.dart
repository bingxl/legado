import 'dart:typed_data';

/// 本地书籍的格式。
///
/// 这个枚举只在「解析」边界使用：入库时 `Book` 实体用字符串存格式
/// （与原版 `BookType` 一致），不要把这个枚举直接持久化，
/// 否则以后加格式就要做数据迁移。
enum BookFormat {
  txt,
  epub,
  umd,
  comic,
  pdf,
  unknown;

  /// 解析失败时给用户看的名字。
  String get displayName => switch (this) {
    BookFormat.txt => '文本',
    BookFormat.epub => 'EPUB',
    BookFormat.umd => 'UMD',
    BookFormat.comic => '漫画',
    BookFormat.pdf => 'PDF',
    BookFormat.unknown => '未知格式',
  };
}

/// 解析后的一章。
///
/// 三种格式的「定位章节」的方式完全不同，因此这里保留三种字段，
/// 而不是硬塞进一个字符串（旧 Go 版把偏移拼成 `"start:end"`，
/// 结果每次取正文都要再解析一次字符串）：
///
/// - txt：`start`/`end` 是**原始文件里的字节偏移**（与原版 `BookChapter` 语义一致，
///   入库后可以直接按偏移重读文件，不必把整本书塞进数据库）；
/// - epub：`href` 是 zip 内的资源路径，可能带 `#fragment`；
/// - umd：`index` 就是章节在正文流里的序号，内容在解析时已取出。
class ParsedChapter {
  const ParsedChapter({
    required this.title,
    required this.index,
    this.content,
    this.contentLoader,
    this.href,
    this.start,
    this.end,
    this.isVolume = false,
  });

  /// 章节标题。目录规则命中时取标题行，兜底时是 `第 N 节` / `封面` 之类。
  final String title;

  /// 全书内的顺序号，从 0 开始。
  final int index;

  /// 解析时就已经拿到的正文（umd/epub 属于这种）。
  final String? content;

  /// 按需取正文的闭包。
  ///
  /// txt 用它在需要时按偏移回读并解码：整本几 MB 的正文如果每章都揣一份字符串，
  /// 打开一本书就要多占一份内存，而读者一次只看一章。
  final String? Function()? contentLoader;

  /// epub 章节指向的 zip 内路径，可能含 `#fragment`。
  final String? href;

  /// txt 章节在原始文件中的起始字节偏移（含标题行）。
  final int? start;

  /// txt 章节在原始文件中的结束字节偏移（下一章标题行起点）。
  final int? end;

  /// epub 里「卷」级别的目录项（有子目录的父节点）。
  /// 拍平后保留这个标记，UI 才能把卷名画成不可点的分组。
  final bool isVolume;

  /// 取正文：优先用已解析的内容，否则调延迟加载闭包。
  String? readContent() => content ?? contentLoader?.call();

  /// epub 章节实际要读的 zip 资源路径（去掉 `#fragment`）。
  String? get resource {
    final h = href;
    if (h == null) return null;
    final i = h.indexOf('#');
    return i < 0 ? h : h.substring(0, i);
  }

  /// epub 章节在资源内的锚点 id，没有则为 null。
  String? get fragment {
    final h = href;
    if (h == null) return null;
    final i = h.indexOf('#');
    if (i < 0 || i == h.length - 1) return null;
    return h.substring(i + 1);
  }

  @override
  String toString() => 'ParsedChapter($index, $title)';
}

/// 解析结果：一本书的结构化形态。
///
/// 只描述「有什么」，不描述「怎么显示」——排版、图片下载、
/// 章节缓存都属于上层，混进来会让内核被迫知道 UI 的事。
class ParsedBook {
  ParsedBook({
    required this.title,
    required this.format,
    required this.chapters,
    this.author,
    Map<String, String>? metadata,
    this.coverBytes,
    List<ComicPage>? pages,
  }) : metadata = metadata ?? const {},
       pages = pages ?? const [];

  final String title;
  final String? author;
  final List<ParsedChapter> chapters;
  final BookFormat format;

  /// 其余元信息（epub 的 description/language/publisher/isbn、umd 的 bookType 等）。
  final Map<String, String> metadata;

  /// 封面原始字节。解析阶段只挑出「看起来有效」的那张，
  /// 解码成位图是 UI 的事，内核不碰图像。
  final Uint8List? coverBytes;

  /// 漫画的页序列（其他格式为空）。
  ///
  /// 页同时以 [chapters] 的形式出现（每页一章，`href` 指向 zip 内路径），
  /// 这样阅读器不必为漫画写第二套"章节"逻辑；需要原始图片字节时走这里。
  final List<ComicPage> pages;

  bool get isEmpty => chapters.isEmpty && pages.isEmpty;

  @override
  String toString() =>
      'ParsedBook($title, $format, ${chapters.length} chapters)';
}

/// 漫画的一页。
///
/// 图片字节可能是几十 MB，全部读进内存会让「打开一本 800 页的漫画」直接 OOM，
/// 所以这里只存路径与惰性读取函数。
class ComicPage {
  ComicPage({required this.name, required this.size, required this.bytes});

  /// zip 内路径（已规范化，含原始子目录）。
  final String name;

  /// 未压缩尺寸，用于 UI 预分配 / 排序稳定性提示。
  final int size;

  /// 读取原始字节。每次调用都从已解压的归档里取一份，
  /// 调用方应缓存自己用到的当前页。
  final Uint8List Function() bytes;

  @override
  String toString() => 'ComicPage($name, $size)';
}

/// 格式本身不支持（rar/7z 漫画、DRM 加密的 epub/umd）。
///
/// 单独立一个异常而不是复用 `LegadoException`：这是**用户可理解**的错误
/// （"请解压成 zip"），上层要原样展示；而 `LegadoException` 是控制面错误码，
/// 会被 UI 当成内部错误统一兜底。
class UnsupportedFormatException implements Exception {
  UnsupportedFormatException(this.message, {this.reason});

  final String message;

  /// 为什么不行（"UMD 已加密，需要专用工具解密"）。
  final String? reason;

  @override
  String toString() =>
      reason == null ? message : '$message（$reason）';
}

/// 文件损坏 / 结构不符合规范。
class BookParseException implements Exception {
  BookParseException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() =>
      cause == null ? '解析失败：$message' : '解析失败：$message（$cause）';
}
