#Requires -Version 7
<#
.SYNOPSIS
  安卓虚拟显示截图（task android:vd:shot 的实现脚本）。
  无窗口跑一次 scrcpy 虚拟显示，录制后挑一帧非黑画面存为 bin/vd-shot.png。

  由 build/android/Taskfile.yml 调用；抽成 pwsh 脚本是为了让任务链只依赖
  go-task 内置 sh + 显式声明的工具（adb/scrcpy/ffmpeg/pwsh），
  不依赖 Git Bash 的 Unix 文本工具（wc/ls -S/tr 等）。
#>
param(
    [string]$DeviceId = '',
    [string]$Scrcpy = '',
    [string]$AppId = 'cn.bingxl.legado',
    [string]$OutDir = 'bin',
    [string]$Size = '720x1280',
    [string]$Dpi = '320',
    [int]$Sec = 12
)

$ErrorActionPreference = 'Stop'
# 经 go-task 管道输出时避免中文/特殊字符乱码（同 sign-dev.ps1 的教训）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 找设备：-DeviceId 优先，否则取第一台非模拟器在线设备 ---
if (-not $DeviceId) {
    foreach ($l in (& adb devices 2>$null)) {
        if ($l -match '^\s*(\S+)\s+device\s*$' -and $Matches[1] -notmatch '^emulator-') {
            $DeviceId = $Matches[1]; break
        }
    }
}
if (-not $DeviceId) {
    Write-Host 'Error: no connected physical Android device found.'
    Write-Host 'Connect by USB, or wirelessly: adb pair <ip:port> && adb connect <ip:port>'
    exit 1
}

# --- 找 scrcpy 并校验版本（Android 16+ 建虚拟显示需 >= 3.3.3）---
$scrcpyBin = $Scrcpy
if (-not $scrcpyBin) {
    $c = Get-Command scrcpy -ErrorAction SilentlyContinue
    if ($c) { $scrcpyBin = $c.Source }
}
if (-not $scrcpyBin) {
    Write-Host 'Error: scrcpy not found. Need >= 3.3.3 for virtual display on Android 16+.'
    Write-Host '  winget install --id Genymobile.scrcpy     # Windows'
    exit 1
}
$verLine = (& $scrcpyBin --version 2>$null | Select-Object -First 1)
if ($verLine -notmatch 'scrcpy\s+([0-9]+)\.([0-9]+)(?:\.([0-9]+))?') {
    Write-Host "Error: cannot parse scrcpy version from: $verLine"
    exit 1
}
$verNum = [int]$Matches[1] * 1000000 + [int]$Matches[2] * 1000 + $(if ($Matches[3]) { [int]$Matches[3] } else { 0 })
if ($verNum -lt 3003003) {
    Write-Host "Error: scrcpy $verLine is too old. Virtual display crashes on Android 16+"
    Write-Host '  (AbstractMethodError: onDisplayAnimationsDisabledChanged; fixed in 3.3.3).'
    Write-Host '  Upgrade: winget upgrade --id Genymobile.scrcpy'
    exit 1
}

# --- ffmpeg（取帧用；不需要 ffprobe）---
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ff) {
    Write-Host 'Error: ffmpeg not found (needed to extract the frame).'
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$mp4 = Join-Path $OutDir '_vd-shot.mp4'
$png = Join-Path $OutDir 'vd-shot.png'
Remove-Item $mp4, $png -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $OutDir '_vd-f*.png') -Force -ErrorAction SilentlyContinue

Write-Host "scrcpy $verLine -> virtual display ${Size}/${Dpi} on $DeviceId (headless capture)"

$attempt = 1
while ($attempt -le 2) {
    & $scrcpyBin -s $DeviceId --no-window --no-audio `
        --new-display="$Size/$Dpi" `
        --start-app=$AppId `
        --no-vd-system-decorations `
        --record="$mp4" --time-limit="$Sec"
    $scrcpyOk = ($LASTEXITCODE -eq 0)

    if ($scrcpyOk -and (Test-Path $mp4)) {
        # 从末尾回退取 4 个候选帧；超出视频长度的会报错，忽略。
        # scrcpy 只编码变化帧，静止界面视频很短，按固定 -ss 取帧会越界；
        # 末尾帧可能是黑帧，所以选体积最大者 —— 纯黑 PNG 十几 KB，正常界面几十 KB+。
        $frames = @()
        foreach ($t in 3, 2, 1, 0) {
            $f = Join-Path $OutDir "_vd-f$t.png"
            & $ff -v quiet -sseof "-$t" -i $mp4 -frames:v 1 -update 1 -y $f 2>$null
            if (Test-Path $f) { $frames += $f }
        }
        $best = $frames |
            Where-Object { (Get-Item $_).Length -gt 20000 } |
            Sort-Object { (Get-Item $_).Length } -Descending |
            Select-Object -First 1
        if ($best) {
            Move-Item $best $png -Force
            break
        }
    }

    # 渲染时长依分辨率/密度而变（1080x1920/240 要 10s+）；取不到内容时翻倍重试一次，
    # 避免把黑图误判成「页面没渲染」。
    Write-Host "No usable frame in ${Sec}s (recorded before the first paint?); retrying with $($Sec * 2)s..."
    $Sec = $Sec * 2
    $attempt++
    Remove-Item $mp4 -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $OutDir '_vd-f*.png') -Force -ErrorAction SilentlyContinue
}
Remove-Item $mp4 -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $OutDir '_vd-f*.png') -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $png)) {
    Write-Host 'Error: still no non-blank frame. The app may have failed to start — check:'
    Write-Host "  adb -s $DeviceId logcat -d | grep -iE 'legado|wails|fatal'"
    exit 1
}
Write-Host "Captured: $png ($((Get-Item $png).Length) bytes)"
