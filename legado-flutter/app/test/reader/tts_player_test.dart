import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/tts_player.dart';

/// 朗读播放器的行为约束。
///
/// 这些用例守的是「静音必须有解释」这条线：系统 TTS 失败时不抛异常、
/// 只是不出声，播放器如果还把状态标成「正在播放」，用户就只能看到
/// 一个永远不动的暂停按钮。所以 speak 被拒、引擎报错、引擎缺失三种情况
/// 都必须落到 [TtsPlayer.error] / [TtsPlayer.status] 上。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_tts');
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall call) onCall;

  setUp(() {
    calls = <MethodCall>[];
    onCall = (call) async => 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return onCall(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 让插件把平台侧回调派发给 Dart 侧 handler。
  Future<void> emit(String method, [Object? arguments]) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );
  }

  List<Map<String, dynamic>> segments(List<String> texts) => <
    Map<String, dynamic>
  >[
    for (var i = 0; i < texts.length; i++)
      <String, dynamic>{'text': texts[i], 'paragraph': i + 1, 'start': 0},
  ];

  Object? argOf(String method) {
    for (final call in calls.reversed) {
      if (call.method == method) return call.arguments;
    }
    return null;
  }

  group('语速换算', () {
    test('1.0 倍 = flutter_tts 的 0.5（Android 侧再映射回 1.0）', () {
      expect(flutterSpeechRate(1.0), 0.5);
      expect(flutterSpeechRate(2.0), 1.0);
      expect(flutterSpeechRate(0.4), 0.2);
    });

    test('超出区间被夹住，不会把非法值发给引擎', () {
      expect(flutterSpeechRate(0.1), 0.2);
      expect(flutterSpeechRate(3.0), 1.0);
    });
  });

  group('看门狗时长', () {
    test('按字数估算，且至少 8 秒、最多 60 秒', () {
      final short = ttsWatchdogTimeout('短句', 1.0);
      expect(short.inSeconds, greaterThanOrEqualTo(8));
      final long = ttsWatchdogTimeout('字' * 40, 1.0);
      expect(long, greaterThan(short));
      expect(ttsWatchdogTimeout('字' * 5000, 1.0).inSeconds, 60);
    });

    test('语速越慢等得越久', () {
      final fast = ttsWatchdogTimeout('字' * 40, 2.0);
      final slow = ttsWatchdogTimeout('字' * 40, 0.5);
      expect(slow, greaterThan(fast));
    });
  });

  group('引擎探测', () {
    test('没有任何引擎时给出可操作的错误，而不是静默', () async {
      onCall = (call) async {
        if (call.method == 'getEngines') return <String>[];
        return 1;
      };
      final player = TtsPlayer(speed: 1.0, pitch: 1.0);
      addTearDown(player.dispose);
      await player.init();
      expect(player.status, TtsEngineStatus.noEngine);
      expect(player.error, contains('语音引擎'));
      expect(player.playing, isFalse);
    });

    test('引擎可用但没有中文语音：状态降级但不阻断英文朗读', () async {
      onCall = (call) async {
        if (call.method == 'getEngines') return <String>['com.example.tts'];
        if (call.method == 'getDefaultEngine') return 'com.example.tts';
        if (call.method == 'isLanguageAvailable') return false;
        if (call.method == 'setLanguage') return 0;
        return 1;
      };
      final player = TtsPlayer();
      addTearDown(player.dispose);
      await player.init();
      expect(player.status, TtsEngineStatus.noChineseVoice);
      expect(player.hasChineseVoice, isFalse);
      expect(player.error, isNull);
    });

    test('中文标签按 zh-CN → zh 回退', () async {
      onCall = (call) async {
        if (call.method == 'getEngines') return <String>['com.example.tts'];
        if (call.method == 'getDefaultEngine') return 'com.example.tts';
        if (call.method == 'isLanguageAvailable') {
          // 只认语族标签的引擎：zh-CN / zh-Hans-CN 都不行。
          return call.arguments == 'zh';
        }
        if (call.method == 'setLanguage') return 1;
        return 1;
      };
      final player = TtsPlayer();
      addTearDown(player.dispose);
      await player.init();
      expect(player.status, TtsEngineStatus.ready);
      expect(argOf('setLanguage'), 'zh');
    });

    test('并发 init 只探测一次（否则后一次会把语言探回默认）', () async {
      var probes = 0;
      onCall = (call) async {
        if (call.method == 'getEngines') {
          probes++;
          return <String>['com.example.tts'];
        }
        if (call.method == 'getDefaultEngine') return 'com.example.tts';
        if (call.method == 'isLanguageAvailable') return true;
        return 1;
      };
      final player = TtsPlayer();
      addTearDown(player.dispose);
      // 面板 initState 与点播放各会调一次 init。
      await Future.wait(<Future<void>>[player.init(), player.init()]);
      expect(probes, 1);
      await player.init(force: true);
      expect(probes, 2, reason: '切引擎要重新探测');
    });

    test('构造时的语速/音调直接下发（1.0 倍 → 0.5）', () async {
      onCall = (call) async {
        if (call.method == 'getEngines') return <String>['com.example.tts'];
        if (call.method == 'getDefaultEngine') return 'com.example.tts';
        if (call.method == 'isLanguageAvailable') return true;
        return 1;
      };
      final player = TtsPlayer(speed: 1.5, pitch: 1.2);
      addTearDown(player.dispose);
      await player.init();
      expect(argOf('setSpeechRate'), 0.75);
      expect(argOf('setPitch'), 1.2);
      expect(argOf('setVolume'), 1.0);
    });
  });

  group('播放推进', () {
    Future<TtsPlayer> readyPlayer() async {
      onCall = (call) async {
        if (call.method == 'getEngines') return <String>['com.example.tts'];
        if (call.method == 'getDefaultEngine') return 'com.example.tts';
        if (call.method == 'isLanguageAvailable') return true;
        if (call.method == 'speak') return 1;
        return 1;
      };
      final player = TtsPlayer();
      await player.init();
      player.load(segments(<String>['第一句', '第二句']));
      return player;
    }

    test('收到 start 后 speaking 为真，done 后自动推进下一句', () async {
      final player = await readyPlayer();
      addTearDown(player.dispose);
      await player.play();
      expect(player.playing, isTrue);
      expect(player.speaking, isFalse, reason: '还没收到 start');

      await emit('speak.onStart');
      expect(player.speaking, isTrue);

      await emit('speak.onComplete');
      await Future<void>.delayed(Duration.zero);
      expect(player.index, 1);
      expect(player.currentText, '第二句');
    });

    test('读到最后一句回调 onFinished', () async {
      var finished = 0;
      onCall = (call) async {
        if (call.method == 'getEngines') return <String>['com.example.tts'];
        if (call.method == 'getDefaultEngine') return 'com.example.tts';
        if (call.method == 'isLanguageAvailable') return true;
        return 1;
      };
      final player = TtsPlayer(onFinished: () async => finished++);
      addTearDown(player.dispose);
      player.load(segments(<String>['唯一一句']));
      await player.play();
      await emit('speak.onStart');
      await emit('speak.onComplete');
      await Future<void>.delayed(Duration.zero);
      expect(finished, 1);
      expect(player.playing, isFalse);
    });

    test('speak 被引擎拒收（返回 0）时立刻报错，不再假装在播', () async {
      onCall = (call) async {
        if (call.method == 'getEngines') return <String>['com.example.tts'];
        if (call.method == 'getDefaultEngine') return 'com.example.tts';
        if (call.method == 'isLanguageAvailable') return true;
        if (call.method == 'speak') return 0;
        return 1;
      };
      final player = TtsPlayer();
      addTearDown(player.dispose);
      player.load(segments(<String>['第一句']));
      await player.play();
      await Future<void>.delayed(Duration.zero);
      expect(player.playing, isFalse);
      expect(player.error, contains('拒绝'));
    });

    test('引擎报错时停止并保留原因', () async {
      final player = await readyPlayer();
      addTearDown(player.dispose);
      await player.play();
      await emit('speak.onStart');
      await emit('speak.onError', 'not bound to TTS engine');
      expect(player.playing, isFalse);
      expect(player.error, contains('not bound to TTS engine'));
    });

    test('stop 之后的迟到回调不会推进队列', () async {
      final player = await readyPlayer();
      addTearDown(player.dispose);
      await player.play();
      await player.stop();
      await emit('speak.onComplete');
      await Future<void>.delayed(Duration.zero);
      expect(player.index, 0);
      expect(player.playing, isFalse);
    });
  });
}
