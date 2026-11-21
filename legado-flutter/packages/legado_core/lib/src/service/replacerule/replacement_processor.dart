/// 替换净化：把 `replace_rules` 表里的规则作用到正文/标题上。
///
/// 语义对齐 Kotlin `AnalyzeRule` + `BookContent`：规则按 `sortOrder` 串行执行，
/// `scope` / `scopeTitle` / `scopeContent` / `excludeScope` 决定这条规则对当前
/// 书名与书源是否生效（匹配用的是「包含」而非全等，和原版一致）。
///
/// 注意净化作用在**上游给到的字符串**上：网络书是书源规则解出的 HTML，
/// 本地书是我们自己拼的 `<p>` HTML。规则里写的 `&nbsp;` / `\n` / 广告域名
/// 在两种形态下都能命中，这是原版一直以来的行为，不要改成先转纯文本。
library;

import 'package:logging/logging.dart';

import '../../domain/domain.dart';
import '../../store/dao/replace_rule_dao.dart';

final Logger _log = Logger('legado.replace');

/// 一次净化要用的上下文：书名 + 书源 URL。
///
/// 两个都参与 `scope` 匹配：规则写「某书源」时靠 origin，写「某本书」时靠书名。
class ReplacementTarget {
  const ReplacementTarget({required this.bookName, required this.origin});

  final String bookName;
  final String origin;

  static const ReplacementTarget empty =
      ReplacementTarget(bookName: '', origin: '');
}

/// 规则执行器。
class ReplacementProcessor {
  ReplacementProcessor(this._dao);

  final ReplaceRuleDao _dao;

  /// 正文净化。命中 `scopeContent` 的启用规则依次串行。
  String content(String text, ReplacementTarget target) {
    if (text.isEmpty) return text;
    return _apply(text, _dao.findEnabledByContentScope(target.bookName, target.origin));
  }

  /// 标题净化。命中 `scopeTitle` 的启用规则依次串行。
  String title(String text, ReplacementTarget target) {
    if (text.isEmpty) return text;
    return _apply(text, _dao.findEnabledByTitleScope(target.bookName, target.origin));
  }

  /// 对任意字符串套用给定的规则列表（供「测试规则」这类显式调用使用）。
  String applyRules(String text, List<ReplaceRule> rules) => _apply(text, rules);

  String _apply(String text, List<ReplaceRule> rules) {
    if (rules.isEmpty) return text;
    var out = text;
    for (final rule in rules) {
      // 原版 `isValid` 会挡掉「pattern 以 | 结尾」这种半截正则，
      // 照抄能避免一条坏规则把整章正文吞掉。
      if (!rule.isValid) continue;
      try {
        out = rule.isRegex
            ? out.replaceAll(RegExp(rule.pattern), rule.replacement)
            : out.replaceAll(rule.pattern, rule.replacement);
      } on FormatException catch (e) {
        // 正则写错不该让整章失败：跳过这一条，留日志给人排查。
        _log.warning('替换规则「${rule.displayNameGroup}」正则非法，已跳过: ${e.message}');
      } on Object catch (e) {
        _log.warning('替换规则「${rule.displayNameGroup}」执行失败，已跳过: $e');
      }
    }
    return out;
  }
}
