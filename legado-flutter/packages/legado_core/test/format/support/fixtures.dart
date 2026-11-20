import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:gbk_codec/gbk_codec.dart' as gbk_codec;

/// 测试素材工厂。
///
/// 全部现造：仓库里塞一个几 MB 的 epub/txt 会让 clone 变慢、也让
/// "测试依赖二进制大文件"这种坏味道扩散。造出来的样本还能精确控制边角
/// （BOM、CRLF、目录页、片段锚点），比真书更适合验证解析器。

/// UTF-8 编码。
Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// GBK 编码（中文测试文本用）。
Uint8List gbkBytes(String text) =>
    Uint8List.fromList(gbk_codec.gbk_bytes.encode(text));

/// UTF-16LE 编码，可选带 BOM。
Uint8List utf16leBytes(String text, {bool bom = true}) {
  final out = <int>[];
  if (bom) out.addAll([0xFF, 0xFE]);
  for (final unit in text.codeUnits) {
    out
      ..add(unit & 0xFF)
      ..add((unit >> 8) & 0xFF);
  }
  return Uint8List.fromList(out);
}

/// 一本 5 章的测试书。
///
/// 每章正文刻意写到 60 字以上：分章算法有"最小间距"约束（滤目录页噪声），
/// 一章只有十几个字时会被当成目录项，测试就测不出真问题了。
String fiveChapterBook({String newline = '\n'}) {
  final lines = <String>[
    '第一章 山雨欲来',
    '　　天色渐暗，风从山脊上压下来，吹得满林的松针一起响。',
    '　　他站在崖边，把信纸折了两折，塞进怀里。',
    '',
    '第二章 夜行',
    '　　夜里没有月亮，只有雪的反光。马蹄声碎，像有人在远处敲鼓。',
    '　　他没有回头，山风灌进领口，冷得像一把薄刀。',
    '',
    '第三章 旧事',
    '　　老掌柜把灯芯挑亮，慢慢说起二十年前那场大火。',
    '　　他说得很慢，仿佛每个字都要先从灰烬里捡起来。',
    '',
    '第四章 长街',
    '　　长街尽头挂着一串红灯笼，风一吹就晃成一片模糊的光。',
    '　　她站在灯下，等一个不会来的人。',
    '',
    '第五章 归途',
    '　　天亮之前，他终于走完了那段山路。',
    '　　山下的城还在睡，炊烟一丝也没有。',
  ];
  return lines.join(newline);
}

/// 用 `archive` 现造一个 zip。
///
/// [entries] 是 "zip 内路径 → 字节"。路径可以带中文或空格，
/// 用来验证解析器的 URL 解码。
///
/// 名为 `mimetype` 的条目按 EPUB 规范**不压缩**：否则 `application/epub+zip`
/// 会被 deflate 掉，格式识别和真实世界的行为就对不上了。
Uint8List buildZip(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, data) {
    final file = ArchiveFile.bytes(name, data);
    if (name == 'mimetype') file.compression = CompressionType.none;
    archive.addFile(file);
  });
  return ZipEncoder().encodeBytes(archive);
}

/// 一个最小可用的 EPUB2（container + opf + ncx + 章节 xhtml）。
Uint8List buildEpub2({
  String title = '测试之书',
  String author = '张三',
  List<String> chapterTitles = const ['第一章 起风', '第二章 落雨'],
  String opfPath = 'OEBPS/content.opf',
}) {
  final base = opfPath.substring(0, opfPath.lastIndexOf('/') + 1);
  final entries = <String, List<int>>{};

  entries['mimetype'] = utf8.encode('application/epub+zip');
  entries['META-INF/container.xml'] = utf8.encode(_containerXml(opfPath));

  final manifest = StringBuffer();
  final spine = StringBuffer();
  final navPoints = StringBuffer();
  for (var i = 0; i < chapterTitles.length; i++) {
    final name = 'chapter${i + 1}.xhtml';
    manifest.writeln(
      '    <item id="c$i" href="$name" media-type="application/xhtml+xml"/>',
    );
    spine.writeln('    <itemref idref="c$i"/>');
    navPoints.writeln(
      '    <navPoint id="np$i" playOrder="${i + 1}">'
      '<navLabel><text>${_escape(chapterTitles[i])}</text></navLabel>'
      '<content src="$name"/></navPoint>',
    );
    entries['$base$name'] = utf8.encode(
      _xhtml(chapterTitles[i], '这是${chapterTitles[i]}的正文段落。\n第二段。'),
    );
  }
  manifest.writeln(
    '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
  );

  entries['${base}toc.ncx'] = utf8.encode(_ncx(title, navPoints.toString()));
  entries[opfPath] = utf8.encode(
    _opf(
      title: title,
      author: author,
      manifest: manifest.toString(),
      spine: spine.toString(),
      ncxId: 'ncx',
    ),
  );
  return buildZip(entries);
}

/// 一个 EPUB3（目录在 xhtml 的 `<nav epub:type="toc">` 里）。
Uint8List buildEpub3Nav({
  String title = 'EPUB3 之书',
  String author = '李四',
  Map<String, List<String>> nested = const {
    '第一卷 少年': ['第一章 出发', '第二章 抵达'],
    '第二卷 归来': ['第三章 旧地'],
  },
}) {
  const opfPath = 'EPUB/package.opf';
  final entries = <String, List<int>>{};

  entries['mimetype'] = utf8.encode('application/epub+zip');
  entries['META-INF/container.xml'] = utf8.encode(_containerXml(opfPath));

  final manifest = StringBuffer();
  final spine = StringBuffer();
  final nav = StringBuffer('<nav epub:type="toc" id="toc"><h1>目录</h1><ol>');
  var fileIndex = 0;
  nested.forEach((volume, chapters) {
    nav.write('<li><span>${_escape(volume)}</span><ol>');
    for (final chapter in chapters) {
      fileIndex++;
      final name = 'text/ch$fileIndex.xhtml';
      manifest.writeln(
        '    <item id="x$fileIndex" href="$name" '
        'media-type="application/xhtml+xml"/>',
      );
      spine.writeln('    <itemref idref="x$fileIndex"/>');
      nav.write('<li><a href="$name">${_escape(chapter)}</a></li>');
      entries['EPUB/$name'] = utf8.encode(
        _xhtml(chapter, '$chapter的正文。第二句话。'),
      );
    }
    nav.write('</ol></li>');
  });
  nav.write('</ol></nav>');

  manifest.writeln(
    '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" '
    'properties="nav"/>',
  );
  entries['EPUB/nav.xhtml'] = utf8.encode(
    '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml" '
    'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head>'
    '<body>$nav</body></html>',
  );
  entries[opfPath] = utf8.encode(
    _opf(
      title: title,
      author: author,
      manifest: manifest.toString(),
      spine: spine.toString(),
      version: '3.0',
    ),
  );
  return buildZip(entries);
}

/// 一个最小 UMD 文件。
///
/// 结构与 `modules/book/.../umdlib` 的 writer 一一对应：
/// 头部属性段 → 正文章节头（总长）→ 章偏移表 → 章标题表 → zlib 压缩正文块 → 结束段。
Uint8List buildUmd({
  String title = 'UMD 测试书',
  String author = '王五',
  List<String> chapterTitles = const ['第一章 开始', '第二章 继续'],
  List<String> contents = const ['这是第一章的内容。\u2029第二段。', '第二章内容。'],
  bool encrypted = false,
}) {
  if (chapterTitles.length != contents.length) {
    throw ArgumentError('标题与正文数量必须一致');
  }
  final out = BytesBuilder();
  void raw(List<int> bytes) => out.add(bytes);
  void byte(int v) => out.addByte(v & 0xFF);
  void u16(int v) {
    byte(v);
    byte(v >> 8);
  }

  void u32(int v) {
    byte(v);
    byte(v >> 8);
    byte(v >> 16);
    byte(v >> 24);
  }

  // 魔数 + 文件类型段
  raw([0x89, 0x9B, 0x9A, 0xDE]);
  byte(0x23); // '#'
  u16(0x01);
  byte(0x00);
  byte(0x08);
  byte(0x01); // 文本类型
  byte(0x12); // 随机数
  byte(0x34);

  // 属性段：type 2=标题 3=作者
  void header(int type, String value) {
    final data = _utf16le(value);
    if (data.isEmpty) return;
    byte(0x23);
    u16(type);
    byte(0x00);
    byte(data.length + 5);
    raw(data);
  }

  header(0x02, title);
  header(0x03, author);

  // 可选：许可证段（0xF1）。真实文件里带 16 字节密钥，解析器应拒绝。
  if (encrypted) {
    byte(0x23);
    u16(0xF1);
    byte(0x00);
    byte(0x15);
    for (var i = 0; i < 16; i++) {
      byte(0x11);
    }
  }

  // 正文章节头：段类型 0x0B，内容是解压后的总字节数
  final contentBytes = <int>[];
  final offsets = <int>[];
  for (final c in contents) {
    offsets.add(contentBytes.length);
    contentBytes.addAll(_utf16le(c));
  }
  byte(0x23);
  u16(0x0B);
  byte(0x00);
  byte(0x09);
  u32(contentBytes.length);

  // 章偏移表：段类型 0x83，附加段里带随机校验数 + 各章起点
  const checkA = 0x10203040;
  byte(0x23);
  u16(0x83);
  byte(0x00);
  byte(0x09);
  u32(checkA);
  byte(0x24); // '$'
  u32(checkA);
  u32(offsets.length * 4 + 9);
  for (final o in offsets) {
    u32(o);
  }

  // 章标题表：段类型 0x84，附加段里同样带校验数
  const checkB = 0x55667788;
  final titleBytes = chapterTitles.map(_utf16le).toList();
  var titlesLen = 0;
  for (final t in titleBytes) {
    titlesLen += t.length + 1;
  }
  byte(0x23);
  u16(0x84);
  byte(0x01); // flag
  byte(0x09); // len（含 5 字节段头）
  u32(checkB);
  byte(0x24);
  u32(checkB);
  u32(titlesLen + 9);
  for (final t in titleBytes) {
    byte(t.length);
    raw(t);
  }

  // 正文块：每块 '$' + 随机数 + 长度 + zlib 压缩数据，块尾再补一个 0xF1 段
  const chunkSize = 32768;
  var start = 0;
  while (start < contentBytes.length) {
    final end = (start + chunkSize < contentBytes.length)
        ? start + chunkSize
        : contentBytes.length;
    final compressed = ZLibEncoder().encodeBytes(
      Uint8List.fromList(contentBytes.sublist(start, end)),
    );
    byte(0x24);
    u32(0x0A0B0C0D);
    u32(compressed.length + 9);
    raw(compressed);
    byte(0x23);
    u16(0xF1);
    byte(0x00);
    byte(0x15);
    for (var i = 0; i < 16; i++) {
      byte(0x00);
    }
    start = end;
  }

  // 结束段：段类型 0x0C
  byte(0x23);
  u16(0x0C);
  byte(0x01); // flag
  byte(0x09);
  u32(0);
  return out.toBytes();
}

List<int> _utf16le(String s) {
  final out = <int>[];
  for (final unit in s.codeUnits) {
    out
      ..add(unit & 0xFF)
      ..add((unit >> 8) & 0xFF);
  }
  return out;
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _containerXml(String opfPath) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="$opfPath" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>';

String _opf({
  required String title,
  required String author,
  required String manifest,
  required String spine,
  String version = '2.0',
  String? ncxId,
}) {
  final ncxAttr = ncxId == null ? '' : ' toc="$ncxId"';
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="$version" '
      'unique-identifier="uid">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>$title</dc:title>'
      '<dc:creator>$author</dc:creator>'
      '<dc:language>zh-CN</dc:language>'
      '<dc:identifier id="uid">urn:uuid:12345678</dc:identifier>'
      '<dc:description>&lt;p&gt;一段简介&lt;/p&gt;</dc:description>'
      '</metadata>'
      '<manifest>$manifest</manifest>'
      '<spine$ncxAttr>$spine</spine>'
      '</package>';
}

String _ncx(String title, String navPoints) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
    '<head><meta name="dtb:uid" content="urn:uuid:12345678"/></head>'
    '<docTitle><text>$title</text></docTitle>'
    '<navMap>$navPoints</navMap></ncx>';

String _xhtml(String title, String body) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<!DOCTYPE html>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$title</title>'
    '<style>p{color:red}</style></head><body>'
    '<h1>${_escape(title)}</h1>'
    '<p>${_escape(body)}</p>'
    '<script>var a=1;</script>'
    '</body></html>';
