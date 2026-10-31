# 本机 SmartScreen「检查应用和文件」档位切换（针对 Windows 11 的应用信誉检查）。
#
# 为什么需要这个脚本：
#   自签名证书无法通过 SmartScreen。SmartScreen 的应用信誉是**云端**判定——它拿文件哈希
#   和签名证书去问微软的 app reputation 服务，返回 Unknown 就按「无法识别的应用」拦。
#   把证书装进 LocalMachine\Root / TrustedPublisher 只影响 Windows 的**本地**链验证
#   （Get-AuthenticodeSignature 显示 Valid、UAC 显示发行者），SmartScreen 完全不参考它。
#   所以「签了名还被拦」是必然结果，不是签名坏了。
#
#   本机开发想让双击直接跑，只有三条路：
#     1. 把这里的档位关掉（本脚本 -Off）：一劳永逸，代价是这台机器不再对
#        下载来的 exe 做信誉预警；
#     2. 每次弹窗点「更多信息 → 仍要运行」：不动系统设置，但每次重建都要点；
#     3. 换成受信任的 OV/EV 代码签名证书（分发场景的唯一正解）。
#
# 用法（管理员 PowerShell）：
#   pwsh -File build/windows/smartscreen-dev.ps1            # 看当前档位
#   pwsh -File build/windows/smartscreen-dev.ps1 -Off       # 关闭「检查应用和文件」
#   pwsh -File build/windows/smartscreen-dev.ps1 -On        # 恢复为 Warn（默认档）
#
# 注：这只改系统/应用文件的检查，不动 Microsoft Edge 的网站防护（那个在 HKCU 下，
# 由 Edge 自己管）。恢复 -On 只是把档位设回 Warn，并不会恢复 Defender 的其他策略。

#Requires -RunAsAdministrator

param(
    [switch]$Off,
    [switch]$On
)

$ErrorActionPreference = "Stop"

if ($Off -and $On) { throw "-Off 和 -On 不能同时给。" }

$key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"
$backupFile = Join-Path $env:ProgramData "legado-smartscreen-backup.txt"

function Get-Current {
    $v = (Get-ItemProperty $key -Name SmartScreenEnabled -ErrorAction SilentlyContinue).SmartScreenEnabled
    if (-not $v) { return "unset(等于 Warn)" }
    return $v
}

function Show-Status {
    $v = Get-Current
    Write-Host "[ss] 当前 SmartScreenEnabled = $v"
    switch ($v) {
        "Off" { Write-Host "[ss] 应用/文件信誉检查已关闭：本机双击自签名 exe 不再被拦" }
        default { Write-Host "[ss] 应用/文件信誉检查开启：自签名 exe 双击会被判「无法识别的应用」" }
    }
}

if (-not $Off -and -not $On) {
    Show-Status
    Write-Host "[ss] 可用参数：-Off（关闭） / -On（恢复 Warn）"
    exit 0
}

if ($Off) {
    $prev = Get-Current
    if (-not (Test-Path $backupFile)) {
        "SmartScreenEnabled=$prev" | Set-Content -Path $backupFile -Encoding UTF8
        Write-Host "[ss] 已记录原档位到 $backupFile"
    }
    Set-ItemProperty -Path $key -Name SmartScreenEnabled -Value "Off" -Type String
    Write-Host "[ss] 已关闭「检查应用和文件」(SmartScreenEnabled=Off)"
    Write-Host "[ss] 若仍拦：注销/重启一次，或确认没有组策略把它改回来（策略优先于本注册表项）"
} else {
    Set-ItemProperty -Path $key -Name SmartScreenEnabled -Value "Warn" -Type String
    Write-Host "[ss] 已恢复 SmartScreenEnabled=Warn"
    if (Test-Path $backupFile) { Remove-Item $backupFile -Force -ErrorAction SilentlyContinue }
}

Show-Status

# 组策略会覆盖本地注册表，顺手报一下，避免「改了没效果」的困惑。
$pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
$polOn = (Get-ItemProperty $pol -Name EnableSmartScreen -ErrorAction SilentlyContinue).EnableSmartScreen
if ($null -ne $polOn) {
    Write-Host "[ss] 警告：检测到组策略 EnableSmartScreen=$polOn（$pol），它会覆盖上面的设置"
}
