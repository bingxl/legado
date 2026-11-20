import 'dart:convert';

import 'package:test/test.dart';

import 'package:legado_core/src/js/java_host.dart';
import 'package:legado_core/src/js/values.dart';

import 'helpers.dart';

/// 从仓库里真实书源（`sources/alicesw_book_source.json`、
/// `app/src/main/assets/defaultData/bookSources.json`）抽出来的脚本。
/// 它们用到的语法比手写用例更野：IIFE、可选链下标、正则 g、
/// 宿主对象再返回宿主对象、`{{page}}` 占位符等。
void main() {
  test('漫画章节列表脚本：解析嵌套转义 JSON 并排序', () async {
    final chapters = [
      {'id': 2, 'number': 2, 'title': '第二话'},
      {'id': 1, 'number': 1, 'title': '第一话'},
    ];
    final payload = '{"code":0,"chapters":${jsonEncode(chapters)}}';
    final html = '<script>var data = $payload;</script>';

    const script = r'''
(function () {
  var html = typeof result !== 'undefined' ? result : '';
  if (!html) {
    java.log('未找到 result 变量');
    return [];
  }
  var MARKER = '\"chapters\":[';
  var idx = html.indexOf(MARKER);
  if (idx < 0) {
    java.log('未找到 chapters 标记');
    return [];
  }
  var arrStart = idx + MARKER.length - 1;
  var i = arrStart, depth = 0, inStr = false, esc = false;
  while (i < html.length) {
    var c = html[i];
    if (esc) { esc = false; i++; continue; }
    if (c === '\\') { esc = true; i++; continue; }
    if (c === '"') { inStr = !inStr; i++; continue; }
    if (!inStr) {
      if (c === '[') depth++;
      else if (c === ']') { depth--; if (depth === 0) break; }
    }
    i++;
  }
  var raw = html.substring(arrStart, i + 1);
  var jsonStr = raw
    .replace(/\\\\/g, '\u0000')
    .replace(/\\"/g, '"')
    .replace(/\u0000/g, '\\');
  var comicId = book.bookUrl.match(/\/comic\/([^/?#]+)/)?.[1];
  java.log('bookid' + comicId);
  if (!comicId) {
    java.log('未能提取 comicId, bookurl:' + book.bookUrl);
    return [];
  }
  var chaptersRaw = JSON.parse(jsonStr);
  var resultList = chaptersRaw.map(function (ch) {
    return {
      number: ch.number,
      title:  ch.title,
      url:    '/read/' + comicId + '/' + ch.id,
    };
  });
  resultList.sort(function (a, b) { return a.number - b.number; });
  return resultList;
})();
''';

    final java = createJavaObject();
    final v = await run(script, bindings: {
      'result': html,
      'book': {'bookUrl': 'https://example.com/comic/abc123?x=1'},
      'java': java,
    });
    expect(v, [
      {'number': 1, 'title': '第一话', 'url': '/read/abc123/1'},
      {'number': 2, 'title': '第二话', 'url': '/read/abc123/2'},
    ]);
  });

  test('图片列表脚本：全局正则 match + forEach + 拼接', () async {
    const script = r'''(function(){
      var imgs = result.match(/<img[^>]+src="([^"]+)"[^>]*>/g) || [];
      var list = [];
      var base = 'https://shenqimanhua.net';
      imgs.forEach(function(img) {
        var m = img.match(/src="([^"]+)"/);
        if (m && m[1].indexOf('/image/') > -1) {
          var src = m[1];
          if (src.indexOf('://') === -1) src = base + src;
          list.push('<img src="' + src + '">');
        }
      });
      return list.join('\n');
    })()''';

    final html = '''
      <div>
        <img src="/image/a.jpg" alt="a">
        <img src="https://cdn.x/image/b.png" alt="b">
        <img src="/other/c.jpg" alt="c">
      </div>
    ''';
    final v = await run(script, bindings: {'result': html});
    expect(v, '<img src="https://shenqimanhua.net/image/a.jpg">\n'
        '<img src="https://cdn.x/image/b.png">');
  });

  test('登录脚本：java.connect 返回宿主对象、读取 body 并写入登录头', () async {
    final loginHeaders = <String>[];
    var authed = false;

    final java = createJavaObject(
      connect: (url, body, headers) {
        if (url.contains('visitorLogin')) {
          authed = true;
          return JsHostObject(methods: {
            'body': (args) => jsonEncode({
                  'statusCode': 200,
                  'content': {'accessToken': 'TOKEN'},
                }),
          });
        }
        // 未登录时返回 401，模拟 token 过期
        if (!authed) {
          return JsHostObject(methods: {
            'body': (args) => '{"statusCode":401}',
          });
        }
        return JsHostObject(methods: {
          'body': (args) => jsonEncode({
                'statusCode': 200,
                'content': [
                  {'categoryName': '玄幻', 'associationCategoryIDs': '1,2'},
                ],
              }),
        });
      },
    );

    const script = r'''
      var header = source.getLoginHeader();
      var json = '';
      var j = null;
      if (header != null) {
        json = java.connect('https://www.kaixin7days.com/book-service/getBookCategroy,{"method":"POST","body":{}}', header).body();
        j = JSON.parse(json);
      }
      if (j == null || j.statusCode != 200) {
        json = java.connect('https://www.kaixin7days.com/visitorLogin,{"method":"POST","body":{}}').body();
        j = JSON.parse(json);
        var accessToken = { Authorization: 'Bearer ' + j.content.accessToken };
        header = JSON.stringify(accessToken);
        source.putLoginHeader(header);
        json = java.connect('https://www.kaixin7days.com/book-service/getBookCategroy,{"method":"POST","body":{}}', header).body();
        j = JSON.parse(json);
      }
      var fls = j.content;
      var fx = [];
      for (var i = 0; i < fls.length; i++) {
        fx.push({
          title: fls[i].categoryName,
          url: '/book-service/getAllBookByCategroyId,{"method":"POST","body":{"categoryIds":"' + fls[i].associationCategoryIDs + '","pageNum":1,"pageSize":100}}'
        });
      }
      JSON.stringify(fx);
    ''';

    final v = await run(script, bindings: {
      'java': java,
      'source': {
        'getLoginHeader': (List<Object?> args) => jsonEncode({'Authorization': 'Bearer OLD'}),
        'putLoginHeader': (List<Object?> args) => loginHeaders.add(args[0] as String),
      },
    });

    expect(v, isA<String>());
    expect(v as String, contains('玄幻'));
    expect(loginHeaders.single, contains('Bearer TOKEN'));
  });
}
