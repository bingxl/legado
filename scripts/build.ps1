# 构建 legado：先编 core，再编 Flutter，最后把 core 放到应用旁。
#
# 用法：
#   pwsh -File scripts/build.ps1                 # Windows release
#   pwsh -File scripts/build.ps1 -Target core     # 只编 core 可执行文件
#   pwsh -File scripts/build.ps1 -Target android  # gomobile bind(AAR) + flutter build apk
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

# Android 需要先把 core 用 gomobile 打成 AAR（Flutter 侧通过 MethodChannel 进程内调用）。
# 三个坑都在这里固化：
#   1) javac 按平台编码（GBK）读 gomobile 生成的 Mobile.java，而里面是 Go 的中文注释
#      → 必须 JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8；
#   2) gomobile 内部的 `go mod tidy` 会碰 sumdb 缓存，偶发 Access denied → GOSUMDB=off；
#   3) 默认 4 个 ABI 且不 strip，AAR 90MB → 只留 arm64+amd64 并 -s -w，压到 27MB。
function Invoke-GomobileBind {
    $sdk = $env:ANDROID_HOME
    if (-not $sdk) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    if (-not (Test-Path $sdk)) { throw "找不到 Android SDK：$sdk（设置 ANDROID_HOME）" }

    $gomobile = Join-Path (go env GOPATH) 'bin\gomobile.exe'
    if (-not (Test-Path $gomobile)) {
        throw "找不到 gomobile。先执行：go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init"
    }

    $ndk = $env:ANDROID_NDK_HOME
    if (-not $ndk) {
        $latest = Get-ChildItem (Join-Path $sdk 'ndk') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) { throw "找不到 NDK（$sdk\ndk 为空）" }
        $ndk = $latest.FullName
    }

    $libs = Join-Path $root 'client\android\app\libs'
    New-Item -ItemType Directory -Force -Path $libs | Out-Null
    $aar = Join-Path $libs 'legado.aar'

    # 环境变量只在本函数内生效，避免污染后面的 flutter 构建。
    $saved = @{
        ANDROID_HOME       = $env:ANDROID_HOME
        ANDROID_NDK_HOME   = $env:ANDROID_NDK_HOME
        JAVA_TOOL_OPTIONS  = $env:JAVA_TOOL_OPTIONS
        GOSUMDB            = $env:GOSUMDB
        GOFLAGS            = $env:GOFLAGS
    }
    try {
        $env:ANDROID_HOME = $sdk
        $env:ANDROID_NDK_HOME = $ndk
        $env:JAVA_TOOL_OPTIONS = '-Dfile.encoding=UTF-8'
        $env:GOSUMDB = 'off'
        $env:GOFLAGS = '-mod=mod'

        Write-Host "==> gomobile bind（AAR → client\android\app\libs）" -ForegroundColor Cyan
        Push-Location (Join-Path $root 'hosts')
        try {
            # -target 的值里有逗号，必须加引号：PS 会把裸逗号当数组分隔符。
            & $gomobile bind '-target=android/arm64,android/amd64' -androidapi 24 `
                '-ldflags=-s -w' -o $aar 'github.com/legado/hosts/ffi/mobile'
            if ($LASTEXITCODE -ne 0) { throw "gomobile bind 失败（exit $LASTEXITCODE）" }
        } finally {
            Pop-Location
        }
    } finally {
        foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
    }
    if (-not (Test-Path $aar)) { throw "AAR 未生成：$aar" }
    Write-Host "    -> $aar ($([math]::Round((Get-Item $aar).Length / 1MB, 1)) MB)"
}

if ($Target -eq 'android') {
    Invoke-GomobileBind
    Push-Location (Join-Path $root 'client')
    try {
        Write-Host "==> flutter build apk --$Configuration" -ForegroundColor Cyan
        & $flutter build apk "--$Configuration"
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk 失败（exit $LASTEXITCODE）" }
    } finally {
        Pop-Location
    }
    return
}

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

        # 本仓库位于 C:\Users\<u>\work（Low Mandatory Level）。go build 会重置标签，
        # 低完整性进程写不了 %LOCALAPPDATA%，表现为 SQLite "unable to open database file (14)"。
        # 构建后统一提到 Medium，双击才正常。
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            foreach ($name in @("legado$ext", "legado-core$ext")) {
                $target = Join-Path $outDir $name
                if (Test-Path $target) { & icacls $target /setintegritylevel M | Out-Null }
            }
        }
    }
} finally {
    Pop-Location
}
