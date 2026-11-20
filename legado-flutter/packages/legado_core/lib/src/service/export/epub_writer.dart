/// EPUB3 打包器（纯 Dart，不依赖 Flutter / dart:ui）。
///
/// 生成的包符合 EPUB 3 的最小可读结构：
/// - `mimetype` 必须是 zip 的**第一个条目且不压缩**（EPUB 规范硬性要求）；
/// - `META-INF/container.xml` 指向 OPF；
/// - `OEBPS/content.opf` + `nav.xhtml`（EPUB3 目录）+ `toc.ncx`（EPUB2 兼容）；
/// - 每章一个 XHTML，正文图片下载后内嵌到 `OEBPS/images/`，链接改写为相对路径。
///
/// 正文来自书源，可能是任意 HTML 片段（含 `<script>`、内联事件、懒加载属性），
/// 这里统一用 `html` 包解析后按白名单序列化成合法 XHTML，既避免坏标签让
/// 阅读器整章白屏，也避免把网页脚本带进离线书。
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parseFragment;

/// 一章正文。
class EpubChapter {
  const EpubChapter({
    required this.index,
    required this.title,
    required this.html,
  });

  final int index;
  final String title;
  final String html;
}

/// 待打包的一本书。
class EpubBook {
  const EpubBook({
    required this.title,
    required this.author,
    required this.intro,
    required this.identifierSeed,
    this.coverUrl = '',
    this.coverBytes,
    this.coverExtension = 'jpg',
    this.chapters = const [],
  });

  final String title;
  final String author;
  final String intro;
  final String identifierSeed;
  final String coverUrl;

  /// 封面字节（由调用方下载后传入；失败则不带封面）。
  final List<int>? coverBytes;
  final String coverExtension;

  final List<EpubChapter> chapters;
}

/// 下载一张图片，返回字节与扩展名（不含点）。
///
/// 返回 null 表示下载失败：正文里保留原始外链，不影响整章导出。
typedef EpubImageFetcher = Future<EpubImage?> Function(String url);

class EpubImage {
  const EpubImage(this.bytes, this.extension);

  final List<int> bytes;
  final String extension;
}

/// 把 [EpubBook] 编成 EPUB 字节。
Future<List<int>> buildEpub(
  EpubBook book, {
  EpubImageFetcher? imageFetcher,
}) async {
  final archive = Archive();

  // EPUB 规范：mimetype 必须第一个且 STORED。archive 的 noCompress 正好对应。
  archive.addFile(
    ArchiveFile.noCompress(
      'mimetype',
      20,
      utf8.encode('application/epub+zip'),
    ),
  );
  archive.addFile(
    ArchiveFile.string(
      'META-INF/container.xml',
      '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''',
    ),
  );

  final hasCover = book.coverBytes != null && book.coverBytes!.isNotEmpty;
  final coverFile = hasCover
      ? 'images/cover.${_safeExtension(book.coverExtension)}'
      : null;
  if (coverFile != null) {
    archive.addFile(
      ArchiveFile.bytes('OEBPS/$coverFile', book.coverBytes!),
    );
  }

  // 图片按 URL 去重，文件名只按出现顺序编号，避免把书源的 query 拼进文件名。
  final imageNames = <String, String>{};

  final chapterEntries = <_ChapterEntry>[];
  for (final chapter in book.chapters) {
    final fragment = parseFragment(chapter.html);
    for (final img in fragment.querySelectorAll('img')) {
      final src = img.attributes['src']?.trim() ?? '';
      if (src.isEmpty || !src.startsWith('http')) continue;
      if (imageNames.containsKey(src)) {
        img.attributes['src'] = '../${imageNames[src]}';
        continue;
      }
      final image = imageFetcher == null ? null : await imageFetcher(src);
      if (image == null || image.bytes.isEmpty) continue;
      final name = 'images/img_${imageNames.length + 1}.${_safeExtension(image.extension)}';
      imageNames[src] = name;
      archive.addFile(ArchiveFile.bytes('OEBPS/$name', image.bytes));
      img.attributes['src'] = '../$name';
    }
    // 去掉网页懒加载残留属性，避免阅读器把 src 当成占位图。
    for (final img in fragment.querySelectorAll('img')) {
      img.attributes.remove('data-src');
      img.attributes.remove('specialdata-src');
      img.attributes.remove('srcset');
    }

    final fileName = 'chapter_${chapter.index.toString().padLeft(4, '0')}.xhtml';
    final body = _serializeNodes(fragment.nodes);
    archive.addFile(
      ArchiveFile.string(
        'OEBPS/text/$fileName',
        _xhtmlDocument(chapter.title, body),
      ),
    );
    chapterEntries.add(_ChapterEntry(chapter.index, chapter.title, fileName));
  }

  if (hasCover) {
    archive.addFile(
      ArchiveFile.string(
        'OEBPS/cover.xhtml',
        _xhtmlDocument(
          '封面',
          '<div class="cover"><img src="$coverFile" alt="cover"/></div>',
        ),
      ),
    );
  }

  final identifier = 'urn:uuid:${_uuidFrom(book.identifierSeed)}';
  final modified = DateTime.now().toUtc().toIso8601String().replaceFirst(
        RegExp(r'\.\d+'),
        '',
      );

  archive.addFile(
    ArchiveFile.string('OEBPS/stylesheet.css', _stylesheet),
  );
  archive.addFile(
    ArchiveFile.string('OEBPS/toc.ncx', _ncx(book.title, identifier, chapterEntries)),
  );
  archive.addFile(
    ArchiveFile.string('OEBPS/nav.xhtml', _nav(chapterEntries)),
  );
  archive.addFile(
    ArchiveFile.string(
      'OEBPS/content.opf',
      _opf(
        book: book,
        identifier: identifier,
        modified: modified,
        chapters: chapterEntries,
        coverFile: coverFile,
        imageFiles: imageNames.values.toSet().toList()..sort(),
      ),
    ),
  );

  return ZipEncoder().encodeBytes(archive);
}

class _ChapterEntry {
  const _ChapterEntry(this.index, this.title, this.fileName);

  final int index;
  final String title;
  final String fileName;
}

const _stylesheet = '''
body { font-family: serif; line-height: 1.7; margin: 1em; }
h1, h2, h3 { line-height: 1.4; }
p { text-indent: 2em; margin: 0.4em 0; }
img { max-width: 100%; height: auto; }
.cover { text-align: center; margin: 0; }
.cover img { max-width: 100%; max-height: 100%; }
''';

/// 只保留安全标签；网页脚本/ iframe 等一律丢弃。
const _dropTags = <String>{
  'script', 'style', 'iframe', 'object', 'embed', 'form', 'input',
  'button', 'select', 'textarea', 'video', 'audio', 'source', 'nav',
};

const _voidTags = <String>{
  'img', 'br', 'hr', 'meta', 'link', 'input', 'source', 'col', 'wbr',
};

String _serializeNodes(List<dom.Node> nodes) {
  final buffer = StringBuffer();
  for (final node in nodes) {
    _serializeNode(node, buffer);
  }
  return buffer.toString();
}

void _serializeNode(dom.Node node, StringBuffer out) {
  if (node is dom.Text) {
    out.write(_xmlText(node.text));
    return;
  }
  if (node is dom.Comment) return;
  if (node is! dom.Element) return;
  final tag = (node.localName ?? '').toLowerCase();
  if (tag.isEmpty || _dropTags.contains(tag)) return;

  final attrs = <String, String>{};
  node.attributes.forEach((Object? key, Object? value) {
    final lower = '$key'.toLowerCase();
    final attrValue = '$value';
    if (lower.startsWith('on')) return;
    if (lower == 'href' && _unsafeScheme(attrValue)) return;
    if (lower == 'src' && _unsafeScheme(attrValue)) return;
    attrs[lower] = attrValue;
  });
  final attrText = attrs.entries
      .map((e) => ' ${e.key}="${_xmlAttr(e.value)}"')
      .join();
  if (_voidTags.contains(tag)) {
    out.write('<$tag$attrText/>');
    return;
  }
  out.write('<$tag$attrText>');
  for (final child in node.nodes) {
    _serializeNode(child, out);
  }
  out.write('</$tag>');
}

bool _unsafeScheme(String value) {
  final lower = value.trimLeft().toLowerCase();
  return lower.startsWith('javascript:') ||
      lower.startsWith('data:') ||
      lower.startsWith('vbscript:');
}

String _xhtmlDocument(String title, String body) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN">
<head>
  <title>${_xmlText(title)}</title>
  <link rel="stylesheet" type="text/css" href="../stylesheet.css"/>
</head>
<body>
$body
</body>
</html>''';

String _opf({
  required EpubBook book,
  required String identifier,
  required String modified,
  required List<_ChapterEntry> chapters,
  required String? coverFile,
  required List<String> imageFiles,
}) {
  final manifest = StringBuffer()
    ..writeln('    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
    ..writeln('    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
    ..writeln('    <item id="css" href="stylesheet.css" media-type="text/css"/>');
  if (coverFile != null) {
    manifest.writeln(
      '    <item id="cover-image" href="$coverFile" media-type="image/${_mimeSubtype(coverFile)}" properties="cover-image"/>',
    );
    manifest.writeln(
      '    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>',
    );
  }
  for (var i = 0; i < imageFiles.length; i++) {
    manifest.writeln(
      '    <item id="img${i + 1}" href="${imageFiles[i]}" media-type="image/${_mimeSubtype(imageFiles[i])}"/>',
    );
  }
  for (final chapter in chapters) {
    manifest.writeln(
      '    <item id="ch${chapter.index}" href="text/${chapter.fileName}" media-type="application/xhtml+xml"/>',
    );
  }

  final spine = StringBuffer();
  if (coverFile != null) spine.writeln('    <itemref idref="cover"/>');
  for (final chapter in chapters) {
    spine.writeln('    <itemref idref="ch${chapter.index}"/>');
  }

  return '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"
         unique-identifier="bookid" xml:lang="zh-CN">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">${_xmlText(identifier)}</dc:identifier>
    <dc:title>${_xmlText(book.title)}</dc:title>
    <dc:creator>${_xmlText(book.author.isEmpty ? '未知作者' : book.author)}</dc:creator>
    <dc:language>zh-CN</dc:language>
    <dc:description>${_xmlText(book.intro)}</dc:description>
    <meta property="dcterms:modified">$modified</meta>
  </metadata>
  <manifest>
$manifest  </manifest>
  <spine toc="ncx">
$spine  </spine>
  <guide>
    <reference type="toc" title="目录" href="nav.xhtml"/>
  </guide>
</package>''';
}

String _nav(List<_ChapterEntry> chapters) {
  final items = StringBuffer();
  for (final chapter in chapters) {
    items.writeln(
      '        <li><a href="text/${chapter.fileName}">${_xmlText(chapter.title)}</a></li>',
    );
  }
  return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh-CN">
<head><title>目录</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>目录</h1>
    <ol>
$items    </ol>
  </nav>
</body>
</html>''';
}

String _ncx(String title, String identifier, List<_ChapterEntry> chapters) {
  final points = StringBuffer();
  for (var i = 0; i < chapters.length; i++) {
    final chapter = chapters[i];
    points.writeln('''    <navPoint id="np${i + 1}" playOrder="${i + 1}">
      <navLabel><text>${_xmlText(chapter.title)}</text></navLabel>
      <content src="text/${chapter.fileName}"/>
    </navPoint>''');
  }
  return '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="zh-CN">
  <head>
    <meta name="dtb:uid" content="${_xmlAttr(identifier)}"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>${_xmlText(title)}</text></docTitle>
  <navMap>
$points  </navMap>
</ncx>''';
}

String _uuidFrom(String seed) {
  final hash = md5.convert(utf8.encode(seed)).toString();
  return '${hash.substring(0, 8)}-${hash.substring(8, 12)}-'
      '${hash.substring(12, 16)}-${hash.substring(16, 20)}-${hash.substring(20)}';
}

String _safeExtension(String raw) {
  final ext = raw.trim().replaceFirst('.', '').toLowerCase();
  return switch (ext) {
    'jpeg' => 'jpg',
    'png' || 'gif' || 'webp' || 'svg' || 'bmp' || 'jpg' => ext,
    _ => 'jpg',
  };
}

String _mimeSubtype(String fileName) =>
    _safeExtension(fileName.split('.').last) == 'jpg'
        ? 'jpeg'
        : _safeExtension(fileName.split('.').last);

String _xmlText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _xmlAttr(String value) => _xmlText(value).replaceAll('"', '&quot;');
