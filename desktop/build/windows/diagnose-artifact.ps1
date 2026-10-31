# 产物自检：一把查出「双击为什么弹警告」。
#
# 用法：
#   pwsh -File build/windows/diagnose-artifact.ps1
#   pwsh -File build/windows/diagnose-artifact.ps1 -Exe "D:\某个副本\legado-desktop.exe"
#
# 输出每一层的结果，最后一节会直接告诉你卡在哪一层、该怎么处理。

param(
    [string]$Exe = ""
)

if (-not $Exe) {
    $Exe = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "bin\legado-desktop.exe"
}
$Exe = [System.IO.Path]::GetFullPath($Exe)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not (Test-Path $Exe)) {
    Write-Host "[x] 文件不存在: $Exe"
    exit 1
}

$f = Get-Item $Exe
Write-Host "===== 文件 ====="
Write-Host "路径    : $($f.FullName)"
Write-Host "大小    : $($f.Length) 字节"
Write-Host "修改时间: $($f.LastWriteTime)"
Write-Host "属性    : $($f.Attributes)"

Write-Host ""
Write-Host "===== 1. Mark-of-the-Web（'来自 Internet 的文件' 警告的唯一触发条件）====="
$streams = Get-Item $Exe -Stream * -ErrorAction SilentlyContinue
$hasMotw = $false
foreach ($s in $streams) {
    Write-Host ("  流: {0,-20} 长度 {1}" -f $s.Stream, $s.Length)
    if ($s.Stream -eq "Zone.Identifier") { $hasMotw = $true }
}
if ($hasMotw) {
    Write-Host "  [!!] 存在 Zone.Identifier —— 双击必定弹「此文件来自 Internet 上的位置」"
    Get-Content $Exe -Stream Zone.Identifier -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "       $_" }
} else {
    Write-Host "  [OK] 无 Zone.Identifier —— 附件管理器不会弹「来自 Internet」"
}

Write-Host ""
Write-Host "===== 2. Authenticode 签名 ====="
$sig = Get-AuthenticodeSignature $Exe
Write-Host "  状态: $($sig.Status)  ($($sig.StatusMessage))"
if ($sig.SignerCertificate) {
    Write-Host "  主题: $($sig.SignerCertificate.Subject)"
    Write-Host "  指纹: $($sig.SignerCertificate.Thumbprint)"
    Write-Host "  到期: $($sig.SignerCertificate.NotAfter)"
    $ekuExt = $sig.SignerCertificate.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.37" }
    Write-Host "  含 EKU 扩展: $([bool]$ekuExt)"
}

Write-Host ""
Write-Host "===== 3. 证书信任存储 ====="
if ($sig.SignerCertificate) {
    $tp = $sig.SignerCertificate.Thumbprint
    foreach ($store in @("Cert:\LocalMachine\Root", "Cert:\LocalMachine\TrustedPublisher", "Cert:\LocalMachine\TrustedPeople")) {
        $hit = Get-ChildItem $store -ErrorAction SilentlyContinue | Where-Object Thumbprint -eq $tp
        Write-Host ("  {0,-40} {1}" -f $store, $(if ($hit) { "已安装" } else { "缺失" }))
    }
} else {
    Write-Host "  [!!] 没有签名者证书，跳过"
}

Write-Host ""
Write-Host "===== 4. SmartScreen / 附件管理器 档位 ====="
$ss = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Name SmartScreenEnabled -ErrorAction SilentlyContinue).SmartScreenEnabled
Write-Host "  SmartScreenEnabled = $(if ($ss) { $ss } else { '<未设置，等效 Warn>' })"
$pol = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name EnableSmartScreen -ErrorAction SilentlyContinue).EnableSmartScreen
Write-Host "  策略 EnableSmartScreen = $(if ($null -ne $pol) { $pol } else { '<无策略>' })"
$sac = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
Write-Host "  Smart App Control = $(if ($null -ne $sac) { $sac } else { '?' })  (0=关闭 1=强制 2=评估)"
$sz = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments" -Name SaveZoneInformation -ErrorAction SilentlyContinue).SaveZoneInformation
Write-Host "  附件管理器 SaveZoneInformation = $(if ($null -ne $sz) { $sz } else { '<未配置（保留区域信息）>' })"

Write-Host ""
Write-Host "===== 结论 ====="
if ($hasMotw) {
    Write-Host "  → 卡在 MOTW。执行：Unblock-File '$Exe'"
    Write-Host "    或者在文件属性 → 常规 里勾「解除锁定」。"
    Write-Host "    若这是网盘/微信/压缩包转来的副本，这属正常，换一份不带标记的即可。"
} elseif ($sig.Status -ne "Valid") {
    Write-Host "  → 卡在签名链（Status=$($sig.Status)）。管理员跑一次 build/windows/setup-dev-cert.ps1"
} elseif ($ss -ne "Off") {
    Write-Host "  → 卡在 SmartScreen（当前 $ss）。本机开发：build/windows/smartscreen-dev.ps1 -Off"
} else {
    Write-Host "  → 四项全干净，这个文件按当前配置不该弹任何警告。"
    Write-Host "    如果仍然弹，请记下弹窗标题和正文，并确认双击的就是上面这个路径。"
}
