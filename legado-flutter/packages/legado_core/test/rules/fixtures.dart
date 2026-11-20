import 'package:legado_core/src/js/js_engine.dart';

/// 测试用 HTML：覆盖块级/行内文本、属性、位置、类名等常见书源结构。
const String sampleHtml = '''
<html><head><title>书页</title></head><body>
<ul id="list" class="book-list">
  <li class="item odd"><a href="/book/1" title="一号"> 书名一 </a><span class="author">作者甲</span></li>
  <li class="item even"><a href="/book/2" title="二号"> 书名二 </a><span class="author">作者乙</span></li>
  <li class="item odd"><a href="/book/3" title="三号"> 书名三 </a><span class="author">作者丙</span></li>
  <li class="item even"><a href="/book/4" title="四号"> 书名四 </a><span class="author">作者丁</span></li>
</ul>
<div id="blocks"><div>块一</div><div>块二</div></div>
<div id="own"> 自己 <span>子</span> </div>
<div id="inline">前<span>中</span>后</div>
<div id="desc"><p>简介第一段</p><p>简介第二段</p></div>
<a id="next" href="/toc?page=2">下一页</a>
<img src="/img/cover.jpg" data-src="//cdn.example.com/c.jpg"/>
</body></html>
''';

/// 测试用 JSON：覆盖数组、嵌套对象、递归下降、过滤。
const String sampleJson = '''
{
  "code": 0,
  "data": {
    "total": 3,
    "list": [
      {"id": 1, "name": "甲", "author": "A", "words": 100, "tags": ["x", "y"], "vip": true},
      {"id": 2, "name": "乙", "author": "B", "words": 200, "tags": ["y"], "vip": false},
      {"id": 3, "name": "丙", "author": "C", "words": 300, "tags": [], "vip": true}
    ],
    "meta": {"name": "abcd", "obj": {"a": 1, "b": 2}}
  },
  "model": {"data": [{"id": 9, "title": "嵌套甲"}, {"id": 10, "title": "嵌套乙"}]}
}
''';

/// 可编程的假 JS 引擎：规则层只依赖接口，测试不需要真解释器。
class FakeJsEngine implements JsEngine {
  FakeJsEngine({this.handler});

  /// 收到脚本与绑定，返回结果。
  final Object? Function(String script, Map<String, Object?> bindings)? handler;

  /// 所有执行过的脚本（断言用）。
  final List<String> scripts = <String>[];

  @override
  Future<Object?> eval(
    String script, {
    Map<String, Object?> bindings = const <String, Object?>{},
  }) async {
    scripts.add(script);
    if (handler != null) return handler!(script, bindings);
    final key = script.trim();
    if (bindings.containsKey(key)) return bindings[key];
    return null;
  }

  @override
  void dispose() {}
}
