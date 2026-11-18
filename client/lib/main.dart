import 'package:flutter/material.dart';

import 'core/bridge/legado_client.dart';
import 'core/router/routes.dart';
import 'core/theme/app_theme.dart';
import 'features/shell/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  String? bootError;
  try {
    await LegadoClient.connect();
  } on LegadoError catch (e) {
    bootError = '${e.code}: ${e.message}';
  } catch (e) {
    bootError = '$e';
  }

  runApp(LegadoApp(bootError: bootError));
}

class LegadoApp extends StatelessWidget {
  const LegadoApp({super.key, this.bootError});

  /// core 连接失败时的提示。为空表示已连上。
  final String? bootError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Legado',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: bootError == null
          ? const HomeShell()
          : _BootErrorPage(message: bootError!),
      // 28 条路由先全部占位，保证任一入口可达（W0 出口条件）。
      routes: {
        for (final name in routeTitles.keys)
          if (name != RouteNames.shelf)
            name: (ctx) => buildPlaceholderRoute(ctx, name),
      },
    );
  }
}

class _BootErrorPage extends StatelessWidget {
  const _BootErrorPage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.link_off, size: 40, color: scheme.error),
                const SizedBox(height: 16),
                Text('无法连接 core', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 20),
                const Text('启动方式：'),
                const SizedBox(height: 4),
                SelectableText(
                  'legado serve -port 8580',
                  style: TextStyle(fontFamily: 'monospace', color: scheme.primary),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    try {
                      await LegadoClient.connect();
                      if (context.mounted) {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(builder: (_) => const HomeShell()),
                        );
                      }
                    } catch (_) {}
                  },
                  child: const Text('重试连接'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
