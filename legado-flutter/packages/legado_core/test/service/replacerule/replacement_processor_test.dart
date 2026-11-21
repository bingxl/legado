import 'dart:io';

import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/service/replacerule/replacement_processor.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 替换净化：规则作用域、正则/纯文本、坏规则容错。
void main() {
  late Directory home;
  late StoreModule store;
  late ReplacementProcessor processor;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-replacement');
    store = StoreModule();
    await store.migrate(ctx());
    processor = ReplacementProcessor(store.daos.replaceRule);
  });

  tearDown(() async {
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  const target = ReplacementTarget(
    bookName: '测试书',
    origin: 'https://example.test',
  );

  void addRule({
    required String pattern,
    String replacement = '',
    bool isRegex = true,
    String? scope,
    String? excludeScope,
    bool scopeContent = true,
    bool scopeTitle = false,
    bool enabled = true,
    int order = 0,
    String name = '规则',
  }) {
    store.daos.replaceRule.insert(
      ReplaceRule(
        name: name,
        pattern: pattern,
        replacement: replacement,
        isRegex: isRegex,
        scope: scope,
        excludeScope: excludeScope,
        scopeContent: scopeContent,
        scopeTitle: scopeTitle,
        isEnabled: enabled,
        order: order,
      ),
    );
  }

  test('纯文本规则替换正文里的广告', () {
    addRule(pattern: '广告', isRegex: false);
    expect(processor.content('<p>正文广告内容</p>', target), '<p>正文内容</p>');
  });

  test('正则规则按 sortOrder 串行执行', () {
    addRule(pattern: r'\s+', replacement: ' ', order: 1, name: '压空白');
    addRule(pattern: '广告', isRegex: false, order: 2, name: '去广告');
    expect(processor.content('正文   广告   内容', target), '正文  内容');
  });

  test('scope 不匹配的书不生效', () {
    addRule(pattern: '广告', isRegex: false, scope: '别的书');
    expect(processor.content('正文广告', target), '正文广告');
  });

  test('excludeScope 命中的书跳过规则', () {
    // excludeScope 与 scope 一样是「包含」匹配，写书名即可命中当前书。
    addRule(
      pattern: '广告',
      isRegex: false,
      scope: '测试书',
      excludeScope: '测试书',
    );
    expect(processor.content('正文广告', target), '正文广告');
  });

  test('scopeTitle 的规则只作用于标题', () {
    addRule(
      pattern: r'最新章节',
      isRegex: false,
      scopeTitle: true,
      scopeContent: false,
    );
    expect(processor.title('最新章节 第1章', target), ' 第1章');
    expect(processor.content('最新章节 第1章', target), '最新章节 第1章');
  });

  test('停用规则不生效', () {
    addRule(pattern: '广告', isRegex: false, enabled: false);
    expect(processor.content('正文广告', target), '正文广告');
  });

  test('非法正则跳过而不是整章失败', () {
    addRule(pattern: '[', replacement: '', name: '坏规则');
    addRule(pattern: '广告', isRegex: false, name: '好规则', order: 1);
    expect(processor.content('正文广告', target), '正文');
  });

  test('以 | 结尾的半截正则被 isValid 挡掉', () {
    addRule(pattern: '广告|', replacement: '', name: '半截');
    expect(processor.content('正文广告', target), '正文广告');
  });
}
