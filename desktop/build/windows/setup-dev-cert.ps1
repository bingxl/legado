# 一次性开发机配置（需要管理员）：
#   1. 把自签名代码签名证书的公钥装进「受信任的根证书颁发机构」和「受信任的发布者」，
#      这样 SignTool / Set-AuthenticodeSignature 签出来的文件在本机链验证为 Valid；
#   2. 把产物路径加入「受控文件夹访问」的允许列表，避免反复重建后被拦写 Documents 等受保护目录。
#
# 用法（管理员 PowerShell）：
#   pwsh -File build/windows/setup-dev-cert.ps1
#   pwsh -File build/windows/setup-dev-cert.ps1 -ExePath "C:\...\bin\legado-desktop.exe"
#
# 注意：只对本机生效。把 exe 发给别人时对方仍会弹 SmartScreen，
# 要彻底消除需要买 OV/EV 代码签名证书。

#Requires -RunAsAdministrator

param(
    [string]$Thumbprint = "",
    [string]$ExePath = ""
)

$ErrorActionPreference = "Stop"

# 通过 sudo / 独立提权窗口运行时看不到 stdout，统一记一份日志备查。
$logPath = Join-Path $env:TEMP "legado-setup-cert.log"
try { Start-Transcript -Path $logPath -Force | Out-Null } catch { }

function Write-Step($msg) { Write-Host "[setup] $msg" }

# ---------- 1. 定位证书 ----------
if (-not $Thumbprint) { $Thumbprint = $env:LEGADO_CODESIGN_THUMBPRINT }
$thumbFile = Join-Path $env:USERPROFILE ".legado-codesign-thumbprint"
if (-not $Thumbprint -and (Test-Path $thumbFile)) {
    $Thumbprint = (Get-Content $thumbFile -Raw).Trim()
}

if (-not $Thumbprint) {
    throw "没有可用的证书指纹。先运行 build/windows/setup-dev-cert.ps1 -Create 之外的步骤：先生成证书（见 README 或 sign-dev.ps1 注释）。"
}

$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
if (-not $cert) { throw "证书 $Thumbprint 不在 CurrentUser\My 中。" }

Write-Step "证书 Subject   : $($cert.Subject)"
Write-Step "证书 Thumbprint: $($cert.Thumbprint)"
Write-Step "有效期至       : $($cert.NotAfter)"

# ---------- 2. 装根证书与受信任发布者 ----------
# 导出的 .cer 只有公钥，留在 build/windows/ 供别的机器用 trust-dev-cert.ps1 导入。
$cerPath = Join-Path $PSScriptRoot "legado-dev-codesign.cer"
Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
Write-Step "已导出公钥证书: $cerPath"

# Root      : 让本机链验证通过（Get-AuthenticodeSignature 显示 Valid）
# TrustedPublisher : 让 UAC / 文件属性直接显示发行者，不再提示「未知发布者」
# TrustedPeople    : MSIX 旁加载（Add-AppxPackage）校验的就是这个存储
foreach ($store in @("Cert:\LocalMachine\Root", "Cert:\LocalMachine\TrustedPublisher", "Cert:\LocalMachine\TrustedPeople")) {
    $already = Get-ChildItem $store -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
    if ($already) {
        Write-Step "$store 已存在该证书，跳过"
        continue
    }
    Import-Certificate -FilePath $cerPath -CertStoreLocation $store | Out-Null
    Write-Step "已导入 $store"
}

# ---------- 3. 受控文件夹访问允许列表 ----------
if (-not $ExePath) {
    $ExePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "bin\legado-desktop.exe"
}
$ExePath = [System.IO.Path]::GetFullPath($ExePath)

$mp = Get-MpPreference
$existing = @($mp.ControlledFolderAccessAllowedApplications | Where-Object { $_ })

if ($existing -contains $ExePath) {
    Write-Step "CFA 允许列表已包含 $ExePath"
} else {
    $merged = @($existing + $ExePath)
    Add-MpPreference -ControlledFolderAccessAllowedApplications $merged
    Write-Step "已把 $ExePath 加入 CFA 允许列表"
}

Write-Step "CFA 当前状态: EnableControlledFolderAccess=$((Get-MpPreference).EnableControlledFolderAccess)"

# ---------- 4. 复核签名 ----------
if (Test-Path $ExePath) {
    $sig = Get-AuthenticodeSignature $ExePath
    Write-Step "产物签名状态: $($sig.Status)"
    if ($sig.Status -eq "NotSigned") {
        Write-Step "提示：产物尚未签名，重新构建（wails3 build）会自动签名"
    }
} else {
    Write-Step "产物不存在（还没构建）: $ExePath"
}

Write-Step "完成。之后每次 wails3 build 都会自动签名，本机链验证为 Valid、UAC 显示发行者、CFA 不再拦写盘。"
Write-Step ""
Write-Step "注意：SmartScreen 仍会拦。它的应用信誉判定在微软云端（按文件哈希 + 证书），"
Write-Step "不参考本机受信任根，自签名证书永远拿不到信誉，所以「无法识别的应用」照旧弹。"
Write-Step "本机开发想双击直接跑：pwsh -File build/windows/smartscreen-dev.ps1 -Off"

try { Stop-Transcript | Out-Null } catch { }
