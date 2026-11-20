// 用真实书源初始化桌面端调试数据目录。
//
// 走 legad_core 的 Source.Import（base64），避免命令行传参长度限制。
import 'dart:convert';
import 'dart:io';

import 'package:legado_core/legado_core.dart';

Future<void> main(List<String> args) async {
  // 数据目录：第一个参数 > 环境变量 LEGADO_HOME > 当前目录下的 .legado-dev
  final home = args.isNotEmpty
      ? args[0]
      : (Platform.environment['LEGADO_HOME'] ?? '.legado-dev');
  final jsonPath = args.length > 1 ? args[1] : '$home/sources.json';

  final core = LegadoCore.instance;
  await core.init(homeDir: home, version: 'dev', host: 'cli');

  final raw = await File(jsonPath).readAsString();
  final list = jsonDecode(raw) as List;
  final b64 = base64Encode(utf8.encode(jsonEncode(list)));

  final res = await core.call('Source.Import', [b64, true]);
  print('导入结果: $res');

  final sources = await core.call('Source.List', []);
  final arr = (sources as List).cast<Map<String, dynamic>>();
  print('书源总数: ${arr.length}');
  for (final s in arr) {
    print('  #${s['id']} ${s['bookSourceName']} | ${s['bookSourceUrl']} | enabled=${s['enabled']}');
  }

  await core.close();
}
