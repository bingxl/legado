# 修「打开文件 - 安全警告」（你想运行此文件吗？/ 来自 Internet 的文件…）。
#
# 这个弹窗**不是** SmartScreen，是附件管理器（IAttachmentExecute）的检查。
# 判定链路：文件属于哪个 IE 安全区域 → 该区域「启动应用程序和不安全文件」(1806) 是否 = 提示(1)。
#   * 文件带 MOTW(Zone.Identifier) → 归 Internet 区（Zone 3）→ 1806 默认 1 → 弹
#   * 文件不带 MOTW            → 归「我的电脑」区（Zone 0）→ 1806 本该是 0（启用）→ 不弹
#
# 所以本地编译的 exe 也会弹，只有两种可能：
#   1. 文件其实带了 MOTW（先用 diagnose-artifact.ps1 确认；有就 Unblock-File）
#   2. Zone 0/1 的 1806 被改成了 1 或被删到回退成严格值（某些安全加固/优化工具会这么干）
#
# 本脚本处理第 2 种。改的是 HKCU，只影响当前用户，-Restore 可完全回滚。
#
# 用法：
#   pwsh -File build/windows/fix-exe-prompt.ps1              # 查看 + 修复 Zone 0/1
#   pwsh -File build/windows/fix-exe-prompt.ps1 -Status      # 只看状态
#   pwsh -File build/windows/fix-exe-prompt.ps1 -LowRiskTypes # 兜底：把 .exe 当低风险类型
#   pwsh -File build/windows/fix-exe-prompt.ps1 -Restore     # 回滚（删掉本脚本写入的值）
#
# 安全说明：Zone 0/1 = 0 是 Windows 的出厂默认（本地程序直接启动，不提示），
# 不降低对"下载来的文件"的防护 —— Internet(3) / 受限(4) 两个区域保持原样。
# -LowRiskTypes 才是有代价的选项：它让**所有** .exe（含网上下载的）都不再提示附件警告，
# 只建议在纯开发机上用。

param(
    [switch]$Status,
    [switch]$LowRiskTypes,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$zones = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones"
$assoc = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Associations"

function Show-Zones {
    Write-Host "[zone] 「启动应用程序和不安全文件」(1806)：0=启用 1=提示 3=禁用"
    foreach ($z in @("0", "1", "2", "3", "4")) {
        $v = (Get-ItemProperty "$zones\$z" -Name 1806 -ErrorAction SilentlyContinue)."1806"
        $n = switch ($z) {
            "0" { "我的电脑(本地)" }
            "1" { "本地 Intranet" }
            "2" { "受信任站点" }
            "3" { "Internet" }
            "4" { "受限站点" }
        }
        $shown = if ($null -ne $v) { "$v" } else { "<未设置，用系统默认>" }
        Write-Host ("    Zone {0} {1,-14} = {2}" -f $z, $n, $shown)
    }
}

function Show-LowRisk {
    $v = (Get-ItemProperty $assoc -Name LowRiskFileTypes -ErrorAction SilentlyContinue).LowRiskFileTypes
    Write-Host "[lowrisk] LowRiskFileTypes = $(if ($v) { $v } else { '<未设置>' })"
}

if ($Status) {
    Show-Zones
    Show-LowRisk
    exit 0
}

if ($Restore) {
    foreach ($z in @("0", "1")) {
        Remove-ItemProperty -Path "$zones\$z" -Name 1806 -ErrorAction SilentlyContinue
        Write-Host "[zone] 已删除 Zone $z 的 1806（回到系统默认）"
    }
    Remove-ItemProperty -Path $assoc -Name LowRiskFileTypes -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $assoc -Name LowRiskFileTypes_Backup -ErrorAction SilentlyContinue
    Write-Host "[lowrisk] 已删除 LowRiskFileTypes"
    Show-Zones
    Show-LowRisk
    exit 0
}

# ---- 修 Zone 0/1：恢复成"本地程序照常启动" ----
foreach ($z in @("0", "1")) {
    if (-not (Test-Path "$zones\$z")) { New-Item -Path "$zones\$z" -Force | Out-Null }
    Set-ItemProperty -Path "$zones\$z" -Name 1806 -Value 0 -Type DWord
}
Write-Host "[zone] 已把 Zone 0 / Zone 1 的 1806 设为 0（本地程序不再弹「你想运行此文件吗」）"

# ---- 兜底：把 .exe 纳入低风险类型 ----
if ($LowRiskTypes) {
    if (-not (Test-Path $assoc)) { New-Item -Path $assoc -Force | Out-Null }
    $old = (Get-ItemProperty $assoc -Name LowRiskFileTypes -ErrorAction SilentlyContinue).LowRiskFileTypes
    if ($old) { Set-ItemProperty -Path $assoc -Name LowRiskFileTypes_Backup -Value $old -Type String }
    $types = if ($old) { $old } else { ";" }
    if ($types -notmatch '\.exe;') {
        if (-not $types.EndsWith(";")) { $types += ";" }
        $types += ".exe;"
    }
    Set-ItemProperty -Path $assoc -Name LowRiskFileTypes -Value $types -Type String
    Write-Host "[lowrisk] 已把 .exe 加入低风险类型: $types"
    Write-Host "[lowrisk] 注意：这会让所有 .exe（含网上下载的）都不再弹附件警告，只建议纯开发机使用"
}

Show-Zones
Show-LowRisk
Write-Host ""
Write-Host "完成。双击那个 exe 试试；仍弹就再跑 diagnose-artifact.ps1 确认到底卡在哪一层。"
