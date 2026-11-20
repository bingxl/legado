/// 统一规则入口（对齐 `AnalyzeRule.kt`）。
///
/// 调用方只关心「给一条规则 + 一个内容，拿到字符串/字符串列表/元素列表」，
/// 至于规则是 CSS、XPath、JSONPath、正则还是内嵌 JS，由 [splitSourceRule] 判定。
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;

import '../util/url.dart';
import 'html_rule.dart';
import 'json_path_rule.dart';
import 'regex_rule.dart';
import 'rule.dart';
import 'xpath_rule.dart';

/// 内容是否为 JSON（对齐 Kotlin `content.toString().isJson()`）。
bool isJsonContent(Object? content) {
  if (content == null) return false;
  if (content is Map || content is List) return true;
  if (content is dom.Node) return false;
  final s = content.toString().trim();
  if (!s.startsWith('{') && !s.startsWith('[')) return false;
  try {
    jsonDecode(s);
    return true;
  } catch (_) {
    return false;
  }
}

/// 规则解析器。无状态，可复用；每次调用显式传内容。
class AnalyzeRule {
  AnalyzeRule(this.context);

  final RuleContext context;

  /// 取字符串列表。失败/无命中返回空列表。
  Future<List<String>> getStringList(
    String? ruleStr, [
    Object? content,
    bool isUrl = false,
  ]) async {
    if (ruleStr == null || ruleStr.isEmpty) return <String>[];
    final root = content;
    final rules = splitSourceRule(ruleStr, contentIsJson: isJsonContent(root));
    if (rules.isEmpty) return <String>[];
    Object? result = root;
    if (result == null) return <String>[];

    for (final sourceRule in rules) {
      await _putRule(sourceRule, root);
      await _makeUp(sourceRule, result, root);
      if (result == null) continue;
      final rule = sourceRule.rule;
      if (rule.isNotEmpty) {
        switch (sourceRule.mode) {
          case RuleMode.js:
            result = await context.evalJs(rule, result);
          case RuleMode.json:
            result = JsonPathRule(result).getStringList(rule);
          case RuleMode.xpath:
            result = XPathRule(_forMarkup(result), baseUrl: context.baseUrl)
                .getStringList(rule);
          case RuleMode.css:
            result = HtmlRule(_forMarkup(result), baseUrl: context.baseUrl)
                .getStringList(rule);
          case RuleMode.regex:
            result = <String>[rule];
        }
      }
      if (result != null && sourceRule.replaceRegex.isNotEmpty) {
        if (result is List) {
          result = [
            for (final item in result)
              applyReplaceRegex(item?.toString() ?? '', sourceRule),
          ];
        } else {
          result = applyReplaceRegex(result.toString(), sourceRule);
        }
      }
    }

    if (result == null) return <String>[];
    List<String> list;
    if (result is String) {
      list = result.split('\n');
    } else if (result is List) {
      list = [for (final e in result) e?.toString() ?? ''];
    } else {
      list = <String>[result.toString()];
    }
    if (isUrl) {
      final urls = <String>[];
      for (final url in list) {
        final abs = getAbsoluteUrl(context.baseUrl, url);
        if (abs.isNotEmpty && !urls.contains(abs)) urls.add(abs);
      }
      return urls;
    }
    return list;
  }

  /// 取字符串（多段用换行连接）。无命中返回空串。
  Future<String> getString(
    String? ruleStr, [
    Object? content,
    bool isUrl = false,
  ]) async {
    if (ruleStr == null || ruleStr.isEmpty) return '';
    final root = content;
    final rules = splitSourceRule(ruleStr, contentIsJson: isJsonContent(root));
    if (rules.isEmpty) return '';
    Object? result = root;

    if (result != null) {
      for (final sourceRule in rules) {
        await _putRule(sourceRule, root);
        await _makeUp(sourceRule, result, root);
        if (result == null) continue;
        final rule = sourceRule.rule;
        if (rule.isNotEmpty || sourceRule.replaceRegex.isEmpty) {
          switch (sourceRule.mode) {
            case RuleMode.js:
              result = await context.evalJs(rule, result);
            case RuleMode.json:
              result = JsonPathRule(result).getString(rule);
            case RuleMode.xpath:
              result =
                  XPathRule(_forMarkup(result), baseUrl: context.baseUrl).getString(rule);
            case RuleMode.css:
              final html = HtmlRule(_forMarkup(result), baseUrl: context.baseUrl);
              result = isUrl ? html.getString0(rule) : html.getString(rule);
            case RuleMode.regex:
              result = rule;
          }
        }
        if (result != null && sourceRule.replaceRegex.isNotEmpty) {
          result = applyReplaceRegex(result.toString(), sourceRule);
        }
      }
    }

    final resultStr = result?.toString() ?? '';
    var str = resultStr;
    if (str.contains('&')) str = htmlUnescape4(str);
    if (isUrl) {
      if (str.trim().isEmpty) return context.baseUrl;
      return getAbsoluteUrl(context.baseUrl, str);
    }
    return str;
  }

  /// 与 [getString] 相同，保留原版命名（service 层可能按此调用）。
  Future<String> getStringEx(
    String? ruleStr, [
    Object? content,
    bool isUrl = false,
  ]) =>
      getString(ruleStr, content, isUrl);

  /// 取元素/对象列表。
  Future<List<Object?>> getElements(String? ruleStr, [Object? content]) async {
    if (ruleStr == null || ruleStr.isEmpty) return <Object?>[];
    final root = content;
    final rules = splitSourceRule(
      ruleStr,
      contentIsJson: isJsonContent(root),
      allInOne: true,
    );
    if (rules.isEmpty) return <Object?>[];
    Object? result = root;
    for (final sourceRule in rules) {
      await _putRule(sourceRule, root);
      await _makeUp(sourceRule, result, root);
      if (result == null) continue;
      switch (sourceRule.mode) {
        case RuleMode.regex:
          result = regexGetElements(
            result.toString(),
            sourceRule.rule.split(RegExp(r'\s*&&\s*')).where((e) => e.isNotEmpty).toList(),
          );
        case RuleMode.js:
          result = await context.evalJs(sourceRule.rule, result);
        case RuleMode.json:
          result = JsonPathRule(result).getList(sourceRule.rule);
        case RuleMode.xpath:
          result = XPathRule(_forMarkup(result), baseUrl: context.baseUrl)
              .getNodes(sourceRule.rule);
        case RuleMode.css:
          result = HtmlRule(_forMarkup(result), baseUrl: context.baseUrl)
              .getElements(sourceRule.rule);
      }
    }
    if (result is List) return List<Object?>.from(result);
    return <Object?>[];
  }

  /// 取单个元素/对象（列表的第一个）；没有则 null。
  Future<Object?> getElement(String? ruleStr, [Object? content]) async {
    final list = await getElements(ruleStr, content);
    return list.isEmpty ? null : list.first;
  }

  /// 上一段结果是「元素列表」时，渲染成 HTML 再交给选择器/XPath
  /// （对齐 Kotlin `getAnalyzeByJSoup(Elements)` 的 `Jsoup.parse(elements.toString())`）。
  Object _forMarkup(Object result) {
    if (result is List) {
      final elements = result.whereType<dom.Element>().toList();
      if (elements.isNotEmpty) {
        return elements.map((e) => e.outerHtml).join();
      }
    }
    return result;
  }

  Future<void> _putRule(SourceRule sourceRule, Object? root) async {
    for (final entry in sourceRule.putMap.entries) {
      final value = await getString(entry.value, root);
      context.putVariable(entry.key, value);
    }
  }

  Future<void> _makeUp(SourceRule sourceRule, Object? result, Object? root) {
    return sourceRule.makeUpRule(
      result,
      evalJs: (script, res) => context.evalJs(script, res),
      getString: (r) => getString(r, root),
      getVar: context.getVariable,
    );
  }
}
