/// 书源规则引擎（M2）。
///
/// 纯 Dart、零 Flutter 依赖；对外只需要 [AnalyzeRule] 与 [RuleContext]。
/// 这个 barrel 不改 `lib/legado_core.dart`（由主控统一接门面），
/// service 层可以 `import 'src/rules/rules.dart'`，或在门面里 re-export。
library;

export 'analyze_rule.dart';
export 'html_rule.dart';
export 'json_path_rule.dart';
export 'regex_rule.dart';
export 'rule.dart';
export 'rule_splitter.dart';
export 'source_rules.dart';
export 'url_rule.dart';
export 'xpath_rule.dart';
