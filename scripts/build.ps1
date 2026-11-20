# 构建 legado（Flutter + 纯 Dart 内核）。
#
# 用法：
#   pwsh -File scripts/build.ps1                        # Windows release
#   pwsh -File scripts/build.ps1 -Target android        # Android APK（release）
#   pwsh -File scripts/build.ps1 -Target cli            # 独立 CLI（bundle 目录，exe + sqlite3.dll）
#   pwsh -File scripts/build.ps1 -Configuration debug
#
# 与旧版的差别：不再有 Go core、不再有 gomobile/AAR/NDK。
# 「同一套 Dart 代码 + 一条 flutter build」就是全部构建流程。
param(
    [ValidateSet('windows', 'android', 'linux', 'cli')]
    [string]$Target = 'windows',
    [ValidateSet('debug', 'release', 'profile')]
    [string]$Configuration = 'release',
    [string]$Version = '0.2.0'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$flutterRoot = Join-Path $root 'legado-flutter'
$appDir = Join-Path $flutterRoot 'app'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# 本机（以及多数国内网络）代理连不上 pub.dev，pub 会报 "Proxy failed to establish tunnel (502)"。
# 只在未显式设置时补镜像，CI 想换源直接设 PUB_HOSTED_URL 覆盖即可。
if (-not $env:PUB_HOSTED_URL) {
    $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
}

function Get-Flutter {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # fvm 是本机实证位置；换机器时优先走 PATH。
    $fvm = 'C:\Users\bingx\fvm\versions\stable\bin\flutter.bat'
    if (Test-Path $fvm) { return $fvm }
    throw '找不到 flutter（PATH 与 fvm 都没有）'
}

function Get-Dart {
    $cmd = Get-Command dart -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fvm = 'C:\Users\bingx\fvm\versions\stable\bin\dart.bat'
    if (Test-Path $fvm) { return $fvm }
    throw '找不到 dart（PATH 与 fvm 都没有）'
}

$flutter = Get-Flutter
$ext = if ($IsWindows -or $env:OS -eq 'Windows_NT') { '.exe' } else { '' }

# CLI 可执行：给不装 Dart 的场景用，同时也是「内核不依赖 Flutter」的最强证明
# —— 能编出独立产物，就说明它真的没碰 UI 框架。
#
# 为什么不是 `dart compile exe`：M1 引入 sqlite3 3.x 后，它走 native assets
# （build/link hooks）把 sqlite3 编进产物，而 `dart compile exe` 明确不支持
# build hooks（"does not support build hooks, use 'dart build' instead"）。
# `dart build cli` 产出的是 bundle 目录：
#   <out>/bundle/bin/legado.exe
#   <out>/bundle/lib/sqlite3.dll      ← exe 按 ../lib 相对路径找它，不能挪
# 代价是「单文件」变成「目录」，换来的是 Windows/Android 都不用自带 dll。
if ($Target -eq 'cli') {
    $dart = Get-Dart
    $outDir = Join-Path $dist 'cli'
    $bundle = Join-Path $outDir 'bundle'
    $exe = Join-Path $bundle "bin\legado$ext"

    # vite 时代留下的教训：递归删除在 Windows 上会撞批量删除保护，
    # 用 .NET API 一次删干净，别用 Remove-Item -Recurse。
    if (Test-Path $outDir) {
        [System.IO.Directory]::Delete($outDir, $true)
    }

    Write-Host "==> dart build cli（$outDir）" -ForegroundColor Cyan
    Push-Location (Join-Path $flutterRoot 'packages/legado_cli')
    try {
        $env:LEGADO_VERSION = $Version
        & $dart build cli -t 'bin/legado.dart' -o $outDir
        if ($LASTEXITCODE -ne 0) { throw "dart build cli 失败（exit $LASTEXITCODE）" }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path $exe)) { throw "未找到产物：$exe" }

    # 与 windows 产物同理：仓库位于 Low Mandatory Level 目录，编译出的 exe 继承受限标签，
    # 运行时连自己的数据目录都建不了（PathAccessException: 拒绝访问, errno 5）。
    if (($IsWindows -or $env:OS -eq 'Windows_NT')) {
        & icacls $exe /setintegritylevel M | Out-Null
    }
    Write-Host "    -> $exe ($([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB)"
    Get-ChildItem (Join-Path $bundle 'lib') -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "       $($_.Name) ($([math]::Round($_.Length / 1MB, 1)) MB)" }
    return
}

Push-Location $appDir
try {
    Write-Host "==> flutter build $Target --$Configuration" -ForegroundColor Cyan
    & $flutter build $Target "--$Configuration" "--dart-define=LEGADO_VERSION=$Version"
    if ($LASTEXITCODE -ne 0) { throw "flutter build 失败（exit $LASTEXITCODE）" }

    if ($Target -eq 'windows') {
        $outDir = Join-Path $appDir "build\windows\x64\runner\$Configuration"
        $exe = Join-Path $outDir "legado$ext"

        # 本仓库位于 C:\Users\<u>\work（Low Mandatory Level）。go build 时代会重置标签，
        # 低完整性进程写不了 %LOCALAPPDATA%，表现为 SQLite "unable to open database file (14)"。
        # Flutter 产物同样可能继承受限标签，构建后统一提到 Medium，双击才正常。
        if (($IsWindows -or $env:OS -eq 'Windows_NT') -and (Test-Path $exe)) {
            & icacls $exe /setintegritylevel M | Out-Null
        }
        Write-Host "    -> $exe"
    }

    if ($Target -eq 'android') {
        $apk = Join-Path $appDir "build\app\outputs\flutter-apk\app-$Configuration.apk"
        if (Test-Path $apk) {
            $target = Join-Path $dist "legado-$Version-$Configuration.apk"
            Copy-Item $apk $target -Force
            Write-Host "    -> $target ($([math]::Round((Get-Item $target).Length / 1MB, 1)) MB)"
        } else {
            Write-Host "    未找到 APK：$apk" -ForegroundColor Yellow
        }
    }
} finally {
    Pop-Location
}
