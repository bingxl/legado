import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'parsed_book.dart';
import 'text_codec.dart';

/// EPUB 2/3 解析器。
///
/// 三个关键决策：
///
/// 1. **XHTML 用 `package:html` 解析，不用 XML 解析器。**
///    EPUB 里的 xhtml 大量不符合 XML（未闭合 `<br>`、`&nbsp;` 未定义实体、
///    缺 `xmlns`），XML 解析器遇到就整体失败；HTML 解析器会"修"。
///    代价是丢掉命名空间信息，而正文根本不需要。
///
/// 2. **目录优先 EPUB3 的 `nav`，回退 EPUB2 的 `toc.ncx`。**
///    两者都拍平成线性列表并保留 `isVolume` 标记——UI 若要树形结构，
///    自己按 `isVolume` 断行重排，比内核返回嵌套结构更好处理。
///
/// 3. **一章可能只是某个 xhtml 里的一段（`#fragment`）。**
///    不少书把一个卷塞进一个文件，靠锚点分章。因此正文按"块"（段落级元素）
///    切开，再用锚点 id 定位首尾；不这么做，整卷内容会在每一章里重复出现。
class EpubParser {
  /// 解析一本 EPUB。失败抛 [BookParseException]。
  ParsedBook parse(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw BookParseException('不是有效的 zip/epub 文件', cause: e);
    }
    final index = _ZipIndex(archive);

    final opfPath = _findOpfPath(index);
    final opfBytes = index.read(opfPath);
    if (opfBytes == null) {
      throw BookParseException('找不到 OPF 文件: $opfPath');
    }
    final opf = _parseXml(opfBytes, 'OPF');
    final opfDir = _dirOf(opfPath);

    final metadata = _parseMetadata(opf);
    final manifest = _parseManifest(opf, opfDir);
    final spinePaths = _parseSpine(opf, manifest);
    final toc = _readToc(
      index: index,
      manifest: manifest,
      spineTocId: _spineTocId(opf),
    );

    final docCache = <String, _DocumentText>{};
    final chapters = <ParsedChapter>[];

    ParsedChapter build({
      required String title,
      required String? path,
      required String? fragment,
      String? endFragment,
      bool isVolume = false,
    }) {
      final href = path == null
          ? null
          : (fragment == null || fragment.isEmpty ? path : '$path#$fragment');
      return ParsedChapter(
        title: title,
        index: chapters.length,
        href: href,
        isVolume: isVolume,
        content: (isVolume || path == null)
            ? null
            : _content(
                index: index,
                path: path,
                fromFragment: fragment,
                toFragment: endFragment,
                cache: docCache,
              ),
      );
    }

    if (toc.isNotEmpty) {
      for (var i = 0; i < toc.length; i++) {
        final entry = toc[i];
        if (entry.path == null) {
          // 卷标题：没有正文资源，只作为分组标记。
          chapters.add(
            build(title: entry.title, path: null, fragment: null,
                isVolume: true),
          );
          continue;
        }
        chapters.add(
          build(
            title: entry.title,
            path: entry.path,
            fragment: entry.fragment,
            endFragment: _nextFragmentInSameFile(toc, i),
          ),
        );
      }
    } else {
      // 目录缺失：退化为 spine 顺序，标题取文档里的 <title>/首个 h1-h3。
      if (spinePaths.isEmpty) {
        throw BookParseException('EPUB 里没有任何可阅读的章节');
      }
      for (var i = 0; i < spinePaths.length; i++) {
        final path = spinePaths[i];
        if (path == null) continue;
        final doc = docCache.putIfAbsent(
          path,
          () => _DocumentText.parse(index.read(path) ?? Uint8List(0)),
        );
        var title = doc.title;
        if (title.isEmpty) title = doc.heading;
        if (title.isEmpty) title = i == 0 ? '封面' : '第 ${i + 1} 节';
        chapters.add(build(title: title, path: path, fragment: null));
      }
    }

    return ParsedBook(
      title: metadata.title.isNotEmpty
          ? metadata.title
          : _fallbackTitle(opfPath),
      author: metadata.author.isEmpty ? null : metadata.author,
      format: BookFormat.epub,
      chapters: chapters,
      metadata: {
        if (metadata.language.isNotEmpty) 'language': metadata.language,
        if (metadata.publisher.isNotEmpty) 'publisher': metadata.publisher,
        if (metadata.identifier.isNotEmpty) 'identifier': metadata.identifier,
        if (metadata.date.isNotEmpty) 'date': metadata.date,
        if (metadata.intro.isNotEmpty) 'intro': metadata.intro,
        'opf': opfPath,
      },
      coverBytes: _findCover(index, manifest, opf),
    );
  }

  // ------------------------------------------------------------ OPF 定位

  String _findOpfPath(_ZipIndex index) {
    final container = index.read('META-INF/container.xml');
    if (container != null) {
      try {
        final doc = XmlDocument.parse(decodeText(container));
        for (final e in doc.descendantElements) {
          if (e.localName != 'rootfile') continue;
          final path = e.getAttribute('full-path');
          if (path != null && path.trim().isNotEmpty) {
            return cleanPath(path);
          }
        }
      } on XmlException {
        // container.xml 坏了就退化成"扫 zip 找 .opf"，不必让整本书失败。
      }
    }
    for (final file in index.files) {
      if (file.name.toLowerCase().endsWith('.opf')) return cleanPath(file.name);
    }
    throw BookParseException('EPUB 结构缺失：既没有 container.xml 也没有 .opf');
  }

  String _fallbackTitle(String opfPath) {
    final base = opfPath.split('/').last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  XmlElement _parseXml(Uint8List bytes, String what) {
    try {
      return XmlDocument.parse(decodeText(bytes)).rootElement;
    } on XmlException catch (e) {
      throw BookParseException('$what 不是合法 XML', cause: e);
    }
  }

  // ------------------------------------------------------------ metadata

  _Metadata _parseMetadata(XmlElement opf) {
    final meta = _Metadata();
    final container = opf.descendantElements
        .where((e) => e.localName == 'metadata')
        .firstOrNull;
    final nodes = container == null
        ? opf.descendantElements
        : container.descendantElements;
    for (final e in nodes) {
      final text = e.innerText.trim();
      switch (e.localName) {
        case 'title':
          if (meta.title.isEmpty) meta.title = cleanText(text);
        case 'creator':
          final name = cleanText(text);
          if (name.isNotEmpty) {
            meta.author = meta.author.isEmpty ? name : '${meta.author}、$name';
          }
        case 'language':
          if (meta.language.isEmpty) meta.language = text;
        case 'publisher':
          if (meta.publisher.isEmpty) meta.publisher = cleanText(text);
        case 'identifier':
          if (meta.identifier.isEmpty) meta.identifier = text;
        case 'date':
          if (meta.date.isEmpty) meta.date = text;
        case 'description':
          // 简介常带 HTML 标签，去掉标签再入库，否则详情页会显示一堆 <p>。
          if (meta.intro.isEmpty) meta.intro = plainText(text);
        case 'meta':
          // EPUB2 的简介有时藏在 <meta name="description" content="...">
          if (e.getAttribute('name')?.toLowerCase() == 'description' &&
              meta.intro.isEmpty) {
            meta.intro = plainText(e.getAttribute('content') ?? '');
          }
      }
    }
    return meta;
  }

  // ------------------------------------------------------------ manifest / spine

  List<_ManifestItem> _parseManifest(XmlElement opf, String opfDir) {
    final items = <_ManifestItem>[];
    for (final e in opf.descendantElements) {
      if (e.localName != 'item') continue;
      final href = e.getAttribute('href')?.trim();
      if (href == null || href.isEmpty) continue;
      items.add(
        _ManifestItem(
          id: e.getAttribute('id') ?? '',
          href: href,
          mediaType: (e.getAttribute('media-type') ?? '').toLowerCase(),
          properties: (e.getAttribute('properties') ?? '').toLowerCase(),
          path: joinPath(opfDir, href),
        ),
      );
    }
    return items;
  }

  /// 返回 spine 里每一项解析后的 zip 内路径（未找到 manifest 项的给 null）。
  List<String?> _parseSpine(XmlElement opf, List<_ManifestItem> manifest) {
    final byId = {for (final m in manifest) m.id: m.path};
    final result = <String?>[];
    for (final e in opf.descendantElements) {
      if (e.localName != 'itemref') continue;
      final idref = e.getAttribute('idref');
      if (idref == null) continue;
      result.add(byId[idref]);
    }
    return result;
  }

  String? _spineTocId(XmlElement opf) {
    for (final e in opf.descendantElements) {
      if (e.localName != 'spine') continue;
      final toc = e.getAttribute('toc')?.trim();
      if (toc != null && toc.isNotEmpty) return toc;
    }
    return null;
  }

  // ------------------------------------------------------------ 目录

  List<_TocEntry> _readToc({
    required _ZipIndex index,
    required List<_ManifestItem> manifest,
    required String? spineTocId,
  }) {
    // EPUB3：manifest 里 properties 含 nav 的 xhtml
    final navItem = manifest
        .where((m) => m.properties.split(RegExp(r'\s+')).contains('nav'))
        .firstOrNull;
    if (navItem != null) {
      final entries = _readNavDoc(index, navItem);
      if (entries.isNotEmpty) return entries;
    }

    // EPUB2：toc.ncx（spine@toc 指的 id，或按 media-type 找）
    var ncx = spineTocId == null
        ? null
        : manifest.where((m) => m.id == spineTocId).firstOrNull;
    ncx ??= manifest
        .where((m) => m.mediaType == 'application/x-dtbncx+xml')
        .firstOrNull;
    if (ncx != null) {
      final entries = _readNcx(index, ncx);
      if (entries.isNotEmpty) return entries;
    }

    // 有些书 properties 写错但文件名就叫 nav.xhtml / toc.xhtml，兜一下。
    for (final m in manifest) {
      final lower = m.href.toLowerCase();
      if (!lower.endsWith('.xhtml') && !lower.endsWith('.html')) continue;
      if (!lower.contains('nav') && !lower.contains('toc')) continue;
      final entries = _readNavDoc(index, m);
      if (entries.isNotEmpty) return entries;
    }
    return const [];
  }

  List<_TocEntry> _readNavDoc(_ZipIndex index, _ManifestItem item) {
    final bytes = index.read(item.path);
    if (bytes == null) return const [];
    final doc = html_parser.parse(decodeText(bytes));
    final navDir = _dirOf(item.path);

    dom.Element? rootList;
    for (final nav in doc.querySelectorAll('nav')) {
      final type = nav.attributes['epub:type'] ?? nav.attributes['type'] ?? '';
      if (type.toLowerCase().contains('toc')) {
        rootList = nav.querySelector('ol');
        break;
      }
    }
    // 没有 epub:type 的退化处理：取第一个带 <ol> 的 nav，再不行取文档里第一个 ol。
    rootList ??= doc.querySelector('nav ol') ?? doc.querySelector('ol');
    if (rootList == null) return const [];

    final entries = <_TocEntry>[];
    void walkList(dom.Element list, int depth) {
      for (final li in list.children.where((e) => e.localName == 'li')) {
        final anchor = li.children
            .where((e) => e.localName == 'a')
            .firstOrNull;
        final span = li.children
            .where((e) => e.localName == 'span')
            .firstOrNull;
        final nested = li.children
            .where((e) => e.localName == 'ol')
            .firstOrNull;

        if (anchor != null) {
          final title = cleanText(anchor.text);
          if (title.isNotEmpty) {
            final target = _splitHref(
              anchor.attributes['href'] ?? '',
              navDir,
              fallbackPath: item.path,
            );
            entries.add(
              _TocEntry(
                title: title,
                path: target.path,
                fragment: target.fragment,
                depth: depth,
              ),
            );
          }
        } else if (span != null && nested != null) {
          // 卷标题：只有 span 没有链接，后面跟一组子项。
          final title = cleanText(span.text);
          if (title.isNotEmpty) {
            entries.add(_TocEntry(title: title, depth: depth));
          }
        }
        if (nested != null) walkList(nested, depth + 1);
      }
    }

    walkList(rootList, 0);
    return entries;
  }

  List<_TocEntry> _readNcx(_ZipIndex index, _ManifestItem item) {
    final bytes = index.read(item.path);
    if (bytes == null) return const [];
    final XmlElement root;
    try {
      root = XmlDocument.parse(decodeText(bytes)).rootElement;
    } on XmlException {
      return const [];
    }
    final ncxDir = _dirOf(item.path);
    final entries = <_TocEntry>[];

    void walk(XmlElement parent, int depth) {
      for (final node in parent.childElements) {
        if (node.localName != 'navPoint') continue;
        var title = '';
        var href = '';
        for (final child in node.childElements) {
          if (child.localName == 'navLabel') {
            for (final t in child.descendantElements) {
              if (t.localName == 'text') {
                title = cleanText(t.innerText);
                break;
              }
            }
          } else if (child.localName == 'content') {
            href = child.getAttribute('src') ?? '';
          }
        }
        if (title.isNotEmpty) {
          final target = _splitHref(
            href,
            ncxDir,
            fallbackPath: item.path,
          );
          entries.add(
            _TocEntry(
              title: title,
              path: target.path,
              fragment: target.fragment,
              depth: depth,
            ),
          );
        }
        walk(node, depth + 1);
      }
    }

    final navMap = root.descendantElements
        .where((e) => e.localName == 'navMap')
        .firstOrNull;
    if (navMap == null) return const [];
    walk(navMap, 0);
    return entries;
  }

  /// 同一文件里下一章的锚点，就是本章的结束位置。
  ///
  /// 换到别的文件（或后面没有章节）时返回 null，表示"读到本文档末尾"。
  static String? _nextFragmentInSameFile(List<_TocEntry> toc, int index) {
    final path = toc[index].path;
    for (var j = index + 1; j < toc.length; j++) {
      final next = toc[j];
      // 卷标题没有正文资源，跳过它继续找下一章。
      if (next.path == null) continue;
      if (next.path != path) return null;
      return next.fragment; // 同文件：可能是 null（下一章从文件开头算）
    }
    return null;
  }

  // ------------------------------------------------------------ 正文

  String? _content({
    required _ZipIndex index,
    required String path,
    required String? fromFragment,
    required String? toFragment,
    required Map<String, _DocumentText> cache,
  }) {
    final doc = cache.putIfAbsent(path, () {
      final bytes = index.read(path);
      return bytes == null
          ? _DocumentText.empty()
          : _DocumentText.parse(bytes);
    });
    if (doc.isEmpty) return null;
    final text = doc.slice(fromFragment, toFragment);
    return text.isEmpty ? null : text;
  }

  // ------------------------------------------------------------ 封面

  Uint8List? _findCover(
    _ZipIndex index,
    List<_ManifestItem> manifest,
    XmlElement opf,
  ) {
    // 1) EPUB3：properties 含 cover-image
    for (final m in manifest) {
      if (m.properties.contains('cover-image')) {
        final data = index.read(m.path);
        if (data != null && data.length > 200) return data;
      }
    }
    // 2) EPUB2：<meta name="cover" content="item-id">
    String? coverId;
    for (final e in opf.descendantElements) {
      if (e.localName != 'meta') continue;
      if (e.getAttribute('name')?.toLowerCase() == 'cover') {
        coverId = e.getAttribute('content');
      }
    }
    if (coverId != null) {
      for (final m in manifest) {
        if (m.id != coverId) continue;
        final data = index.read(m.path);
        if (data != null && data.length > 200) return data;
      }
    }
    // 3) 最后按 id/文件名里带 cover 的图片猜一张
    for (final m in manifest) {
      if (!m.mediaType.startsWith('image/')) continue;
      if (!'${m.id} ${m.href}'.toLowerCase().contains('cover')) continue;
      final data = index.read(m.path);
      if (data != null && data.length > 200) return data;
    }
    return null;
  }
}

// ---------------------------------------------------------------- 共用工具

/// zip 内路径规范化：反斜杠、`./`、重复斜杠、`..`。
String cleanPath(String path) {
  final parts = <String>[];
  for (final seg in path.replaceAll('\\', '/').split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(seg);
  }
  return parts.join('/');
}

/// 目录路径（带尾斜杠）。
String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i + 1);
}

/// 把相对 href 拼成 zip 内路径，顺便解码 `%20`。
String joinPath(String baseDir, String href) =>
    _splitHref(href, baseDir).path ?? '';

/// 拆 href 为「zip 内路径 + 锚点」。
///
/// [fallbackPath] 用于 `#id` 这种纯锚点：它指向当前文档自身。
_Href _splitHref(String href, String baseDir, {String? fallbackPath}) {
  var raw = href.trim();
  String? fragment;
  final hash = raw.indexOf('#');
  if (hash >= 0) {
    fragment = raw.substring(hash + 1);
    raw = raw.substring(0, hash);
  }
  if (fragment != null && fragment.isEmpty) fragment = null;
  raw = _percentDecode(raw);
  if (raw.isEmpty) return _Href(fragment == null ? null : fallbackPath, fragment);
  final query = raw.indexOf('?');
  if (query >= 0) raw = raw.substring(0, query);
  return _Href(cleanPath('$baseDir$raw'), fragment);
}

String _percentDecode(String value) {
  if (!value.contains('%')) return value;
  try {
    return Uri.decodeFull(value);
  } on ArgumentError {
    return value;
  }
}

/// 折叠空白（含全角空格）并去首尾。
String cleanText(String value) =>
    value.replaceAll(RegExp(r'[\s\u3000]+'), ' ').trim();

/// 去标签、折叠空白。
String plainText(String input) {
  if (input.isEmpty) return '';
  if (!input.contains('<')) return cleanText(input);
  return cleanText(html_parser.parseFragment(input).text ?? '');
}

/// zip 内资源索引：大小写不敏感，并兼容 `%XX` 编码的文件名。
class _ZipIndex {
  _ZipIndex(Archive archive) {
    for (final file in archive.files) {
      if (file.isDirectory) continue;
      _byKey.putIfAbsent(_normalize(file.name), () => file);
    }
  }

  final Map<String, ArchiveFile> _byKey = {};

  /// 去重后的条目（用于"没有 container 时扫 .opf"）。
  Iterable<ArchiveFile> get files => _byKey.values;

  static String _normalize(String name) {
    var key = name.replaceAll('\\', '/').toLowerCase();
    while (key.startsWith('./')) {
      key = key.substring(2);
    }
    return key;
  }

  Uint8List? read(String path) {
    final candidates = <String>[_normalize(path)];
    // 中文/空格文件名在不同打包器里可能被 URL 编码，两种写法都试。
    if (path.contains('%')) {
      try {
        candidates.add(_normalize(Uri.decodeFull(path)));
      } on ArgumentError {
        // 非法转义序列，保持原样
      }
    }
    for (final key in candidates) {
      final data = _byKey[key]?.readBytes();
      if (data != null) return data;
    }
    return null;
  }
}

/// 正文文档：按段落块切开，并记录锚点 id 落点。
///
/// 一个 xhtml 可能包含整卷内容，靠 `#id` 分章。这里把"块"和"锚点"建立映射，
/// 取某章正文就是块区间拼接，不必在 HTML 字符串上做脆弱的切片。
class _DocumentText {
  _DocumentText(this.blocks, this.title, this.heading);

  factory _DocumentText.empty() =>
      _DocumentText(const [], '', '');

  final List<_TextBlock> blocks;
  final String title;
  final String heading;

  bool get isEmpty => blocks.isEmpty;

  static _DocumentText parse(Uint8List bytes) {
    final doc = html_parser.parse(decodeText(bytes));
    final body = doc.body;
    final blocks = <_TextBlock>[];
    final buffer = StringBuffer();
    final pendingIds = <String>[];

    void flush() {
      final text = cleanText(buffer.toString());
      buffer.clear();
      if (text.isEmpty && pendingIds.isEmpty) return;
      blocks.add(_TextBlock(text, pendingIds.firstOrNull));
      pendingIds.clear();
    }

    void walk(dom.Element element) {
      final tag = element.localName;
      if (tag == 'script' || tag == 'style' || tag == 'title' ||
          tag == 'head') {
        return;
      }
      final isBlock = _blockTags.contains(tag);
      if (isBlock) flush();
      final id = element.id;
      if (id.isNotEmpty) pendingIds.add(id);
      for (final node in element.nodes) {
        if (node is dom.Text) {
          buffer.write(node.text);
        } else if (node is dom.Element) {
          walk(node);
        }
      }
      if (isBlock) flush();
    }

    if (body != null) walk(body);

    final titleEl = doc.querySelector('title');
    final title = titleEl == null ? '' : cleanText(titleEl.text);
    var heading = '';
    for (final tag in const ['h1', 'h2', 'h3']) {
      final el = body?.querySelector(tag);
      if (el != null) {
        heading = cleanText(el.text);
        if (heading.isNotEmpty) break;
      }
    }
    return _DocumentText(blocks, title, heading);
  }

  /// 取 [fromId] 到 [toId] 之间的正文；[toId] 为 null 表示到文档末尾。
  String slice(String? fromId, String? toId) {
    var from = 0;
    if (fromId != null) {
      final i = blocks.indexWhere((b) => b.id == fromId);
      if (i >= 0) from = i;
    }
    var to = blocks.length;
    if (toId != null && toId != fromId) {
      final i = blocks.indexWhere((b) => b.id == toId, from);
      if (i > from) to = i;
    }
    final parts = <String>[];
    for (var i = from; i < to; i++) {
      final text = blocks[i].text;
      if (text.isNotEmpty) parts.add(text);
    }
    return parts.join('\n');
  }
}

/// 段落级标签：遇到就开始新的一段。
const _blockTags = {
  'p',
  'div',
  'br',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'ul',
  'ol',
  'tr',
  'td',
  'th',
  'table',
  'blockquote',
  'section',
  'article',
  'pre',
  'hr',
  'body',
  'figure',
  'figcaption',
  'aside',
  'header',
  'footer',
};

class _TextBlock {
  const _TextBlock(this.text, this.id);

  final String text;
  final String? id;
}

class _Href {
  const _Href(this.path, this.fragment);

  final String? path;
  final String? fragment;
}

class _ManifestItem {
  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.properties,
    required this.path,
  });

  final String id;
  final String href;
  final String mediaType;
  final String properties;
  final String path;
}

class _TocEntry {
  const _TocEntry({
    required this.title,
    this.path,
    this.fragment,
    this.depth = 0,
  });

  final String title;
  final String? path;
  final String? fragment;
  final int depth;
}

class _Metadata {
  String title = '';
  String author = '';
  String language = '';
  String publisher = '';
  String identifier = '';
  String date = '';
  String intro = '';
}
