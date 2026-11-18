# 构建 legado：先编 core，再编 Flutter，最后把 core 放到应用旁。
#
# 用法：
#   pwsh -File scripts/build.ps1                 # Windows release
#   pwsh -File scripts/build.ps1 -Target core    # 只编 core 可执行文件
#   pwsh -File scripts/build.ps1 -Configuration debug
param(
    [ValidateSet('windows', 'android', 'linux', 'core')]
    [string]$Target = 'windows',
    [ValidateSet('debug', 'release', 'profile')]
    [string]$Configuration = 'release',
    [string]$Version = '0.1.0'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# Flutter 优先用 PATH，其次用 fvm（本机实证位置）。
function Get-Flutter {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fvm = 'C:\Users\bingx\fvm\versions\stable\bin\flutter.bat'
    if (Test-Path $fvm) { return $fvm }
    throw '找不到 flutter（PATH 与 fvm 都没有）'
}

$ext = if ($IsWindows -or $env:OS -eq 'Windows_NT') { '.exe' } else { '' }

Write-Host "==> 构建 core (hosts/cli)" -ForegroundColor Cyan
Push-Location (Join-Path $root 'hosts')
try {
    go build -trimpath `
        -ldflags "-s -w -X github.com/legado/hosts/rt.Version=$Version" `
        -o (Join-Path $dist "legado-core$ext") ./cli
} finally {
    Pop-Location
}
Write-Host "    -> dist/legado-core$ext"

if ($Target -eq 'core') { return }

$flutter = Get-Flutter
Push-Location (Join-Path $root 'client')
try {
    Write-Host "==> flutter build $Target --$Configuration" -ForegroundColor Cyan
    & $flutter build $Target "--$Configuration"
    if ($LASTEXITCODE -ne 0) { throw "flutter build 失败（exit $LASTEXITCODE）" }

    if ($Target -eq 'windows') {
        # 必须叫 legado-core：与应用 exe 同名会互相覆盖（踩过一次）。
        $outDir = Join-Path $root "client\build\windows\x64\runner\$Configuration"
        Copy-Item (Join-Path $dist "legado-core$ext") (Join-Path $outDir "legado-core$ext") -Force
        Write-Host "    -> $outDir\legado-core$ext"
    }
} finally {
    Pop-Location
}
