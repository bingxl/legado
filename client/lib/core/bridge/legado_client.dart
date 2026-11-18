import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 桥接层错误。code 与 Go 侧 kernel 错误码一致（NOT_FOUND / INVALID_ARGUMENT …）。
class LegadoError implements Exception {
  const LegadoError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// 与 Go core 的控制面通道。
///
/// 传输形态有两种，协议完全相同（请求信封 `{id,method,args}`，响应 `{ok,data,err}`）：
///   1. loopback HTTP —— 当前默认，core 以独立进程运行（headless 优先）
///   2. FFI（dart:ffi → legado.dll）—— 需要 C 工具链，后续接入
///
/// 约定：UI 不得绕过本类直接发业务 HTTP，也不得自行解析书源规则。
class LegadoClient {
  LegadoClient._(this._base);

  static LegadoClient? _instance;
  static LegadoClient get instance {
    final c = _instance;
    if (c == null) {
      throw StateError('bridge 尚未初始化，请先 await LegadoClient.connect()');
    }
    return c;
  }

  static bool get isReady => _instance != null;

  final Uri _base;
  int _seq = 0;
  Process? _process;

  Uri get baseUrl => _base;

  /// 连接 core：优先已有端点，其次尝试拉起 `legado serve`。
  static Future<LegadoClient> connect() async {
    if (_instance != null) return _instance!;

    final forced = const String.fromEnvironment('LEGADO_ENDPOINT');
    if (forced.isNotEmpty) {
      final c = LegadoClient._(Uri.parse(forced));
      await c._assertHealthy();
      _instance = c;
      return c;
    }

    final envEndpoint = Platform.environment['LEGADO_ENDPOINT'];
    if (envEndpoint != null && envEndpoint.isNotEmpty) {
      final c = LegadoClient._(Uri.parse(envEndpoint));
      await c._assertHealthy();
      _instance = c;
      return c;
    }

    // 开发期默认端口：`legado serve -port 8580`
    final dev = LegadoClient._(Uri.parse('http://127.0.0.1:8580'));
    if (await dev._healthy()) {
      _instance = dev;
      return dev;
    }

    // 尝试拉起随包分发的 core 可执行文件。
    final exe = _locateCoreBinary();
    if (exe != null) {
      final c = await _spawn(exe);
      _instance = c;
      return c;
    }

    throw LegadoError(
      'CORE_UNAVAILABLE',
      '未找到 legado core。请先运行 `legado serve -port 8580`，'
          '或用 --dart-define=LEGADO_CORE=<路径> 指定可执行文件。',
    );
  }

  static String? _locateCoreBinary() {
    final defined = const String.fromEnvironment('LEGADO_CORE');
    if (defined.isNotEmpty && File(defined).existsSync()) return defined;

    // 注意：core 可执行文件**不能**与 Flutter 应用同名（两者都叫 legado.exe 时
    // 会互相覆盖），因此固定用 legado-core 这个名字，放在应用同目录或 core/ 子目录。
    final exeDir = File(Platform.resolvedExecutable).parent;
    final name = 'legado-core${Platform.isWindows ? '.exe' : ''}';
    final sep = Platform.pathSeparator;
    final candidates = <String>[
      '${exeDir.path}$sep$name',
      '${exeDir.path}${sep}core$sep$name',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  static Future<LegadoClient> _spawn(String exe) async {
    final proc = await Process.start(exe, ['serve', '-port', '0']);
    final completer = Completer<LegadoClient>();
    final buffer = StringBuffer();

    late StreamSubscription<String> sub;
    sub = proc.stdout.transform(utf8.decoder).listen((chunk) {
      buffer.write(chunk);
      final line = buffer.toString().split('\n').firstWhere(
            (l) => l.startsWith('listening '),
            orElse: () => '',
          );
      if (line.isNotEmpty && !completer.isCompleted) {
        final url = line.substring('listening '.length).trim();
        _instanceFor(url, proc, sub, completer);
      }
    });
    proc.stderr.transform(utf8.decoder).listen((_) {});

    // 5 秒内没有 ready 就判定失败，避免 UI 无限转圈。
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        proc.kill();
        throw const LegadoError('CORE_TIMEOUT', 'core 启动超时');
      },
    );
  }

  static void _instanceFor(
    String url,
    Process proc,
    StreamSubscription<String> sub,
    Completer<LegadoClient> completer,
  ) {
    final c = LegadoClient._(Uri.parse(url));
    c._process = proc;
    sub.cancel();
    if (!completer.isCompleted) completer.complete(c);
  }

  Future<bool> _healthy() async {
    try {
      final r = await http
          .get(_base.resolve('/healthz'))
          .timeout(const Duration(milliseconds: 800));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _assertHealthy() async {
    if (!await _healthy()) {
      throw LegadoError('CORE_UNAVAILABLE', '端点不可用: $_base');
    }
  }

  /// 调用 core 方法。args 为**位置参数**，与 Go 方法签名顺序一致。
  Future<dynamic> call(String method, [List<Object?> args = const []]) async {
    final body = jsonEncode({'id': ++_seq, 'method': method, 'args': args});
    late http.Response resp;
    try {
      resp = await http
          .post(
            _base.resolve('/rpc'),
            headers: const {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw const LegadoError('NET_TIMEOUT', 'core 响应超时');
    }

    final Map<String, dynamic> map;
    try {
      map = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw LegadoError('BAD_RESPONSE', 'core 返回非 JSON（HTTP ${resp.statusCode}）');
    }
    if (map['ok'] == true) return map['data'];
    final err = map['err'];
    if (err is Map) {
      throw LegadoError('${err['code']}', '${err['msg']}');
    }
    throw LegadoError('UNKNOWN', '未知错误（HTTP ${resp.statusCode}）');
  }

  /// 便捷：把结果当 List<Map> 使用。
  Future<List<Map<String, dynamic>>> callList(
    String method, [
    List<Object?> args = const [],
  ]) async {
    final data = await call(method, args);
    if (data == null) return const [];
    return (data as List).cast<Map<String, dynamic>>();
  }

  Future<void> dispose() async {
    _process?.kill();
    _process = null;
    if (identical(_instance, this)) _instance = null;
  }
}
