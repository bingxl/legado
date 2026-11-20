// Build hook for quickjs_runtime: compiles the vendored QuickJS 2024-01-13
// C sources and quickjs_bridge.c into a bundled CodeAsset so Flutter apps
// (iOS, Android, macOS, Linux, Windows) and `dart run` / `dart test` work
// out of the box without running `tool/build_quickjs.sh` manually.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const String _assetName = 'src/quickjs_ffi.dart';

/// Windows SDK 的 UCRT 头/库路径。
///
/// 正常情况下 vcvars64.bat 会把它们注入 INCLUDE/LIB；但在受限沙箱里
/// vcvars 依赖的 reg.exe 可能被拦截，导致 INCLUDE 只有 MSVC 自身头文件，
/// cl.exe 编译 xmmintrin.h 时报 `malloc.h: No such file or directory`。
/// 这里显式把 UCRT include/lib 追加为编译参数，不依赖注册表查询。
List<String> _windowsSdkPaths() {
  final roots = <Directory>[];
  final envRoot = Platform.environment['WindowsSDKDir'];
  if (envRoot != null && envRoot.isNotEmpty) {
    roots.add(Directory(envRoot));
  }
  final kits = Directory(r'C:\Windows Kits\10');
  if (kits.existsSync()) roots.add(kits);

  for (final root in roots) {
    final includeDir = Directory('${root.path}\\Include');
    if (!includeDir.existsSync()) continue;
    final versions = includeDir
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split(RegExp(r'[\\/]')).last)
        .where((v) => RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(v))
        .toList()
      ..sort();
    if (versions.isEmpty) continue;
    final ver = versions.last;
    return [
      '${includeDir.path}\\$ver\\ucrt',
      '${includeDir.path}\\$ver\\shared',
      '${includeDir.path}\\$ver\\um',
      '${root.path}\\Lib\\$ver\\ucrt\\x64',
      '${root.path}\\Lib\\$ver\\um\\x64',
    ];
  }
  return const [];
}

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    final isWindows = os == OS.windows;
    final sdkPaths = isWindows ? _windowsSdkPaths() : const <String>[];
    final sdkIncludes = sdkPaths.take(3).toList();
    final sdkLibDirs = sdkPaths.skip(3).toList();
    final builder = CBuilder.library(
      name: 'quickjs_bridge',
      assetName: _assetName,
      sources: const [
        'native/quickjs_bridge.c',
        'native/quickjs/quickjs.c',
        'native/quickjs/libregexp.c',
        'native/quickjs/libunicode.c',
        'native/quickjs/cutils.c',
        'native/quickjs/libbf.c',
      ],
      // On Windows the MSVC toolchain (native_toolchain_c resolves cl.exe)
      // cannot compile the vendored GCC-oriented QuickJS sources as-is.
      // native/quickjs/msvc provides a forced-include compatibility shim
      // (sys/time.h, alloca, strdup, atomics, intrinsics) plus a shim
      // include dir that satisfies quickjs.c's <sys/time.h>. Other
      // platforms are untouched.
      includes: isWindows
          ? ['native/quickjs/msvc', 'native/quickjs', ...sdkIncludes]
          : const ['native/quickjs'],
      forcedIncludes: isWindows
          ? const ['native/quickjs/msvc/msvc_compat.h']
          : const [],
      defines: const {
        '_GNU_SOURCE': null,
        'CONFIG_VERSION': '"2024-01-13"',
      },
      // 显式给出 UCRT 库路径；vcvars 在受限环境里可能拿不到 LIB。
      // libraryDirectories 会被放到 /link 之后，顺序正确。
      libraryDirectories: isWindows ? sdkLibDirs : const [],
      flags: isWindows
          ? const []
          : [
              '-Wno-implicit-const-int-float-conversion',
              '-Wno-unused-parameter',
              '-Wno-sign-compare',
              if (os == OS.android) '-Wl,-z,max-page-size=16384',
              if (os == OS.iOS || os == OS.macOS) ...[
                '-headerpad_max_install_names',
                '-install_name',
                '@rpath/libquickjs_bridge.dylib',
              ],
            ],
      libraries: isWindows
          ? const []
          : [
              'm',
              // bionic 把 pthread 并进了 libc，NDK r29 不再提供 libpthread
              // （链接会报 "unable to find library -lpthread"）。
              if (os != OS.android) 'pthread',
              if (os == OS.linux || os == OS.android) 'dl',
            ],
      optimizationLevel: OptimizationLevel.o2,
    );
    await builder.run(input: input, output: output);
  });
}
