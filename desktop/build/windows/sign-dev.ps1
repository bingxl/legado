# 用本机自签名证书给 Windows 产物签名。
#
# 为什么需要：exe 未签名时，Defender / SmartScreen 归其为「未知应用」——
# 每次重建哈希都变，CDA（受控文件夹访问）会拦它写受保护目录，SmartScreen 也会弹
# 「无法识别的应用」。签名给文件一个稳定的发布者身份，配合本机受信任根证书即可消除。
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

# UnknownError 表示签名已写入、但根证书还没进本机受信任根。
# 这是初次配置时的正常状态，装上根证书后同一签名会变成 Valid。
switch ($r.Status) {
    "Valid" {
        Write-Host "[sign] OK (chain trusted)"
        exit 0
    }
    "UnknownError" {
        Write-Host "[sign] signature written, but the self-signed root is not trusted on this machine"
        Write-Host "[sign] run build/windows/setup-dev-cert.ps1 as administrator once to trust it"
        exit 0
    }
    default {
        Write-Host "[sign] FAILED: $($r.Status) - $($r.StatusMessage)"
        exit 1
    }
}
