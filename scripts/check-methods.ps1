# 交叉校验：Flutter/Dart 侧引用的方法名是否都真的存在于 core 注册表。
#
# 为什么需要这个脚本：控制面方法名是字符串常量（`'Shelf.ListBooks'`），
# 既不参与 Go 编译、也不参与 Dart 编译——拼错一个字母，编译期一切正常，
# 运行期才发现「按钮点了没反应」。把两边对一遍只需几百毫秒，比手点页面便宜。
#
# 用法：
#   pwsh -File scripts/check-methods.ps1
# 退出码 0 表示全部命中，1 表示有 Dart 引用了不存在的方法。

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$clientLib = Join-Path $root 'client/lib'
$coreExe = Join-Path $root 'dist/legado-core.exe'

if (-not (Test-Path $coreExe)) {
    throw "找不到 $coreExe。先构建：cd hosts; go build -o ../dist/legado-core.exe ./cli"
}

# 1) core 侧：`legado methods` 每行形如 `Settings.Update([patch map[string]string]) -> ([])`
$goMethods = & $coreExe methods |
    ForEach-Object { if ($_ -match '^([A-Za-z]+\.[A-Za-z.]+)') { $Matches[1] } } |
    Sort-Object -Unique

if ($goMethods.Count -eq 0) {
    throw '从 legado-core methods 里没有解析出任何方法名，输出格式可能变了。'
}

# 2) Dart 侧：所有形如 'Domain.Verb' 的字符串字面量
#    单引号包裹、以已知域名为前缀，避免把日志文案误判成方法名。
#    **必须区分大小写**：设置项的键叫 `reader.fontSize`，与域 `Reader` 只差一个字母，
#    不区分大小写会把它当成方法名报出十条假失败。
$domains = ($goMethods | ForEach-Object { ($_ -split '\.')[0] } | Sort-Object -Unique) -join '|'
$pattern = "'((?:$domains)\.[A-Za-z.]+)'"
$dartMethods = Get-ChildItem -Path $clientLib -Recurse -Filter *.dart |
    ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } |
    Select-String -Pattern $pattern -AllMatches -CaseSensitive |
    ForEach-Object { $_.Matches } |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique

# 3) 差集（-c 前缀：区分大小写，避免上面那种误判）
$missing = $dartMethods | Where-Object { $goMethods -cnotcontains $_ }
$unused = $goMethods | Where-Object { $dartMethods -cnotcontains $_ }

Write-Host "core 提供 $($goMethods.Count) 个方法，Dart 引用了 $($dartMethods.Count) 个"

if ($missing) {
    Write-Host ''
    Write-Host '以下方法在 Dart 里有引用，但 core 没有注册：' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

# 未被 UI 用到的量是健康度指标（很多方法只给 CLI 用），不当作失败。
Write-Host "Dart 未引用 $($unused.Count) 个（多数只供 CLI/桌面使用，属正常）"
Write-Host 'OK: Dart 引用的方法全部存在' -ForegroundColor Green
exit 0
