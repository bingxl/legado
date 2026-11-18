import 'dart:convert';
import 'dart:io';

import 'package:legado_core/legado_core.dart';
import 'package:test/test.dart';

void main() {
  group('Registry', () {
    late Registry registry;

    setUp(() {
      registry = Registry();
      registry.method(
        'Demo.Add',
        (args) async => (args[0] as int) + (args[1] as int),
        params: const ['a int', 'b int'],
        doc: '相加',
      );
    });

    test('按位置参数调用', () async {
      expect(await registry.invoke('Demo.Add', [2, 3]), 5);
    });

    test('未知方法给出 NOT_FOUND 而不是空指针', () async {
      await expectLater(
        registry.invoke('Nope.Missing', const []),
        throwsA(
          isA<LegadoException>().having(
            (e) => e.code,
            'code',
            ErrorCode.notFound,
          ),
        ),
      );
    });

    test('参数类型不匹配翻译成 INVALID_ARGUMENT', () async {
      await expectLater(
        registry.invoke('Demo.Add', ['a', 'b']),
        throwsA(
          isA<LegadoException>().having(
            (e) => e.code,
            'code',
            ErrorCode.invalid,
          ),
        ),
      );
    });

    test('参数缺失不会漏出 RangeError', () async {
      await expectLater(
        registry.invoke('Demo.Add', [1]),
        throwsA(
          isA<LegadoException>().having(
            (e) => e.code,
            'code',
            ErrorCode.invalid,
          ),
        ),
      );
    });

    test('重复注册直接失败（重名会让调用方打到别的方法上）', () {
      expect(
        () => registry.method('Demo.Add', (args) async => null),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Envelope', () {
    late Registry registry;

    setUp(() {
      registry = Registry();
      registry.method('Demo.Echo', (args) async => args, params: const ['v any']);
    });

    test('成功信封带 id 与 data', () async {
      final raw = await Envelope.handle(
        registry,
        jsonEncode({'id': 7, 'method': 'Demo.Echo', 'args': ['x']}),
      );
      final map = jsonDecode(raw) as Map<String, dynamic>;
      expect(map['id'], 7);
      expect(map['ok'], isTrue);
      expect(map['data'], ['x']);
    });

    test('失败信封带 code/msg，且不抛异常', () async {
      final raw = await Envelope.handle(
        registry,
        jsonEncode({'id': 8, 'method': 'Demo.Nope', 'args': []}),
      );
      final map = jsonDecode(raw) as Map<String, dynamic>;
      expect(map['ok'], isFalse);
      expect(map['id'], 8);
      expect(map['err']['code'], ErrorCode.notFound);
    });

    test('非法 JSON 返回 INVALID_ARGUMENT 而不是崩掉', () async {
      final raw = await Envelope.handle(registry, '{oops');
      final map = jsonDecode(raw) as Map<String, dynamic>;
      expect(map['err']['code'], ErrorCode.invalid);
    });

    test('args 不是数组时明确报错', () async {
      final raw = await Envelope.handle(
        registry,
        jsonEncode({'id': 1, 'method': 'Demo.Echo', 'args': {'a': 1}}),
      );
      final map = jsonDecode(raw) as Map<String, dynamic>;
      expect(map['err']['code'], ErrorCode.invalid);
    });
  });

  group('LegadoCore', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('legado-core-test');
    });

    tearDown(() async {
      await LegadoCore.instance.close();
      if (home.existsSync()) home.deleteSync(recursive: true);
    });

    test('init 后 System.Info 可用，且方法表非空', () async {
      final core = LegadoCore.instance;
      await core.init(homeDir: home.path, version: 'test-1.0');

      final info = await core.call('System.Info') as Map<String, Object?>;
      expect(info['version'], 'test-1.0');
      expect(info['home'], home.path);

      final methods = core.methods();
      expect(methods.map((m) => m.name), contains('System.Info'));
      expect(core.methods('System').length, methods.length);
    });

    test('未初始化调用给出明确错误', () {
      expect(
        () => LegadoCore.instance.call('System.Info'),
        throwsA(isA<LegadoException>()),
      );
    });

    test('重复 init 幂等（热重载会重复走到这里）', () async {
      final core = LegadoCore.instance;
      await core.init(homeDir: home.path);
      await core.init(homeDir: home.path);
      expect(core.isReady, isTrue);
    });
  });
}
