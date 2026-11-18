# 交叉校验：Flutter 侧引用的方法名是否都真的在内核里注册过。
#
# 为什么需要这个脚本：控制面方法名是字符串常量（`'Shelf.ListBooks'`），
# 既不参与 Dart 编译、也不参与内核编译——拼错一个字母，编译期一切正常，
# 运行期才发现「按钮点了没反应」。把两边对一遍只需几秒，比手点页面便宜。
#
# 用法：
#   pwsh -File scripts/check-methods.ps1            # 只报告，总是退出 0（迁移期用）
#   pwsh -File scripts/check-methods.ps1 -Strict    # 有缺失即退出 1（CI 用）
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$flutterRoot = Join-Path $root 'legado-flutter'
$appLib = Join-Path $flutterRoot 'app/lib'
$cliDir = Join-Path $flutterRoot 'packages/legado_cli'

# Dart 的输出是 UTF-8，而 Windows 控制台默认 GBK。不解码的话中文注释会变乱码，
# 更麻烦的是多字节字符会把行尾换行吃掉，导致两条方法名被粘成一行（解析直接漏方法）。
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# 本机代理连不上 pub.dev，dart run 解析依赖时会用到 pub 镜像。
if (-not $env:PUB_HOSTED_URL) { $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn' }

$dart = Get-Command dart -ErrorAction SilentlyContinue
if ($dart) { $dart = $dart.Source }
else {
    $fvm = 'C:\Users\bingx\fvm\versions\stable\bin\dart.bat'
    if (-not (Test-Path $fvm)) { throw '找不到 dart（PATH 与 fvm 都没有）' }
    $dart = $fvm
}

if (-not (Test-Path $appLib)) { throw "找不到 $appLib" }

# 1) 内核侧：`legado methods` 每行形如 `Shelf.ListBooks(bookId int)  // 说明`
#    注意必须真的跑内核，不能 grep 源码：注册是运行期行为（模块 register() 里做的），
#    静态扫描会漏掉所有通过循环/辅助函数注册的方法。
Push-Location $cliDir
try {
    $raw = & $dart run bin/legado.dart methods 2>&1
} finally {
    Pop-Location
}

if ($LASTEXITCODE -ne 0) {
    $raw | ForEach-Object { Write-Host $_ }
    throw 'legado methods 执行失败'
}

$coreMethods = $raw |
    ForEach-Object { if ($_ -match '^\s*([A-Za-z]+\.[A-Za-z.]+)') { $Matches[1] } } |
    Sort-Object -Unique

if ($coreMethods.Count -eq 0) {
    throw '没有从 legado methods 里解析出任何方法名，输出格式可能变了。'
}

# 2) Dart 侧：所有形如 'Domain.Verb' 的字符串字面量。
#    只认已知域名做前缀，避免把日志文案误判成方法名；
#    **必须区分大小写**：设置项的键叫 `reader.fontSize`，与域 `Reader` 只差一个字母，
#    不区分大小写会把它当成方法名报出十条假失败。
$domains = ($coreMethods | ForEach-Object { ($_ -split '\.')[0] } | Sort-Object -Unique) -join '|'
$pattern = "'((?:$domains)\.[A-Za-z.]+)'"
$dartMethods = Get-ChildItem -Path $appLib -Recurse -Filter *.dart |
    ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } |
    Select-String -Pattern $pattern -AllMatches -CaseSensitive |
    ForEach-Object { $_.Matches } |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique

# 3) 差集（-c 前缀：区分大小写，避免上面那种误判）
$missing = @($dartMethods | Where-Object { $coreMethods -cnotcontains $_ })
$unused = @($coreMethods | Where-Object { $dartMethods -cnotcontains $_ })

Write-Host "内核提供 $($coreMethods.Count) 个方法，Dart 引用了 $($dartMethods.Count) 个"

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host "以下 $($missing.Count) 个方法在 Dart 里有引用，但内核尚未注册：" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '迁移期这是预期结果（UI 先行、内核分批补齐）；-Strict 下才算失败。' -ForegroundColor DarkGray
    if ($Strict) { exit 1 }
}

# 未被 UI 用到的量是健康度指标（很多方法只给 CLI 用），不当作失败。
Write-Host "内核未被 UI 引用 $($unused.Count) 个（多数只供 CLI 使用，属正常）"

if ($missing.Count -eq 0) {
    Write-Host 'OK: Dart 引用的方法全部存在' -ForegroundColor Green
}
exit 0
