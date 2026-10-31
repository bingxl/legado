# 在**另一台机器**上信任本项目的自签名代码签名证书。
#
# 适用场景：把 bin/legado-desktop.exe 拷到测试机 / 另一台开发机，双击后：
#   * UAC 与文件属性显示「未知发布者」；
#   * 用 MSIX 旁加载时 Add-AppxPackage 报证书链不可信（0x800B0109）。
# 跑这个脚本后这两项都会好。
#
# 但它**不会**让 SmartScreen 闭嘴——SmartScreen 的信誉判定在微软云端，与本机信任链无关。
# 见 build/windows/smartscreen-dev.ps1 顶部说明。
#
# 用法（管理员 PowerShell）：
#   pwsh -File build/windows/trust-dev-cert.ps1                      # 用同目录的 .cer
#   pwsh -File build/windows/trust-dev-cert.ps1 -CerPath D:\x.cer    # 用指定文件
#
# 前置：主开发机先跑过一次 setup-dev-cert.ps1，会导出
# build/windows/legado-dev-codesign.cer（只有公钥，可以随仓库/构建产物一起分发）。
#
# 安全提示：把证书导入 LocalMachine\Root 等于无条件信任"任何用这张私钥签名的代码"。
# 私钥只在主开发机上，别把 .pfx / 私钥带出去；但同团队机器上导入公钥是常规做法。

#Requires -RunAsAdministrator

param(
    [string]$CerPath = ""
)

$ErrorActionPreference = "Stop"

if (-not $CerPath) { $CerPath = Join-Path $PSScriptRoot "legado-dev-codesign.cer" }
if (-not (Test-Path $CerPath)) {
    throw "找不到证书文件: $CerPath`n先在签名的机器上跑一次 build/windows/setup-dev-cert.ps1，它会导出这个 .cer。"
}

$cer = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    [System.IO.Path]::GetFullPath($CerPath))
Write-Host "[trust] 证书 Subject : $($cer.Subject)"
Write-Host "[trust] 证书 Thumbprint: $($cer.Thumbprint)"
Write-Host "[trust] 有效期至     : $($cer.NotAfter)"

foreach ($store in @("Cert:\LocalMachine\Root", "Cert:\LocalMachine\TrustedPublisher", "Cert:\LocalMachine\TrustedPeople")) {
    $already = Get-ChildItem $store -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $cer.Thumbprint }
    if ($already) {
        Write-Host "[trust] $store 已存在，跳过"
        continue
    }
    Import-Certificate -FilePath ([System.IO.Path]::GetFullPath($CerPath)) -CertStoreLocation $store | Out-Null
    Write-Host "[trust] 已导入 $store"
}

Write-Host "[trust] 完成。"
Write-Host "[trust] 验证已签名的产物：Get-AuthenticodeSignature <exe> 应显示 Status=Valid"
Write-Host "[trust] SmartScreen 不在此列——它只看云端信誉，自签名永远拦。"
