# 用本机自签名证书给 Windows 产物签名。
#
# 这个脚本能解决的问题（且只解决这些）：
#   * 让「受控文件夹访问 (CFA)」按发布者而不是哈希认人，重建后不再被拦写受保护目录；
#   * 让文件属性里显示真实发行者，而不是「未知发布者」；
#   * 让本机签名链验证为 Valid（前提：根证书已装进 LocalMachine\Root）。
#
# 这个脚本**不能**解决的问题：SmartScreen。
#   SmartScreen 的应用信誉判定走微软云端（针对文件哈希 + 签名证书），
#   **完全不看本地受信任根**。自签名证书在微软侧永远没有信誉记录，所以不管签多少次、
#   装得多干净，Warn 档的「检查应用和文件」依旧会拦，文案就是
#   「Microsoft Defender SmartScreen 阻止了无法识别的应用启动」。
#   这不是签名坏了——用 Get-AuthenticodeSignature 会看到 Status=Valid。
#   真正能让它不弹的办法见 build/windows/smartscreen-dev.ps1 和 README 的说明。
#
# 证书指纹来源优先级：
#   1. -Thumbprint 参数
#   2. 环境变量 LEGADO_CODESIGN_THUMBPRINT
#   3. %USERPROFILE%\.legado-codesign-thumbprint
#
# 证书不存在时只警告、退出码 0（不让构建失败，CI 或他人机器上没有这张证书）。

param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Thumbprint = ""
)

$ErrorActionPreference = "Stop"

# task (go-task) 用管道捕获本脚本输出，Git Bash 侧按 UTF-8 解析。
# 不显式设成 UTF-8 时 PowerShell 按系统 ANSI 代码页(936)写管道，中文会变成乱码。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not (Test-Path $Exe)) {
    Write-Host "[sign] target not found: $Exe"
    exit 1
}

if (-not $Thumbprint) { $Thumbprint = $env:LEGADO_CODESIGN_THUMBPRINT }
$thumbFile = Join-Path $env:USERPROFILE ".legado-codesign-thumbprint"
if (-not $Thumbprint -and (Test-Path $thumbFile)) {
    $Thumbprint = (Get-Content $thumbFile -Raw).Trim()
}

if (-not $Thumbprint) {
    Write-Host "[sign] no code-signing thumbprint configured, skipping (run build/windows/setup-dev-cert.ps1 to create one)"
    exit 0
}

$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1

if (-not $cert) {
    Write-Host "[sign] certificate $Thumbprint not found in CurrentUser\My, skipping"
    exit 0
}

if ($cert.NotAfter -lt (Get-Date)) {
    Write-Host "[sign] certificate expired on $($cert.NotAfter), skipping"
    exit 0
}

Write-Host "[sign] signing $Exe"
Write-Host "[sign]   subject   : $($cert.Subject)"
Write-Host "[sign]   thumbprint: $($cert.Thumbprint)"
Write-Host "[sign]   expires   : $($cert.NotAfter)"

try {
    $r = Set-AuthenticodeSignature -FilePath $Exe -Certificate $cert -HashAlgorithm SHA256
} catch {
    Write-Host "[sign] FAILED: $($_.Exception.Message)"
    exit 1
}

# 清掉 Mark-of-the-Web。产物若落在 OneDrive / 下载目录 / 被同步盘加过 Zone.Identifier，
# 双击时 SmartScreen 一定会来检查；本地构建本来就不该带这个流。
try {
    Unblock-File -Path $Exe -ErrorAction SilentlyContinue
} catch { }

switch ($r.Status) {
    "Valid" {
        Write-Host "[sign] OK (chain trusted)"
    }
    "UnknownError" {
        Write-Host "[sign] signature written, but the self-signed root is not trusted on this machine"
        Write-Host "[sign] run build/windows/setup-dev-cert.ps1 as administrator once to trust it"
    }
    default {
        Write-Host "[sign] FAILED: $($r.Status) - $($r.StatusMessage)"
        exit 1
    }
}

# SmartScreen 是独立的一层，和上面的签名链结果无关。这里把状态摊开说清楚，
# 免得下次又误判成「签名没生效」。
$ss = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Name SmartScreenEnabled -ErrorAction SilentlyContinue).SmartScreenEnabled
if (-not $ss) { $ss = "unset" }
Write-Host "[sign] note: SmartScreen 档位 = $ss"
if ($ss -ne "Off") {
    Write-Host "[sign] SmartScreen 不信任自签名证书（云端信誉，与本地根证书无关），双击仍会弹"
    Write-Host "[sign] 「无法识别的应用」。本机开发想直接双击跑：build/windows/smartscreen-dev.ps1 -Off"
}

exit 0
