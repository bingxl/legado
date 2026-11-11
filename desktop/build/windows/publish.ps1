# 发布可执行文件到工作区之外，让资源管理器双击可以正常启动。
#
# 背景：本仓库位于 C:\Users\<用户>\work 下，而 work 目录被施加了
# "Mandatory Label\Low Mandatory Level"（低完整性标签）+ Everyone 的 DENY(DELETE_CHILD)。
# Windows 的 MIC（强制完整性控制）规则是：完整性级别低于调用进程的镜像**不可执行**。
# 于是普通权限的资源管理器双击工作区里的 exe 会**静默失败**（进程根本没起来，
# 没有任何报错），只有以管理员身份运行（High IL）才能启动——这正是
# "双击打不开、必须以管理员权限才能运行" 的成因，与应用本身无关
# （把系统 notepad.exe 放进同一目录同样起不来）。
#
# 把 exe 复制到默认 Medium 标签的目录即可恢复正常，因此发布目录不能放在 work 下。
# 另外构建链会给 bin 产物设一条显式 Medium 标签（见 fix-integrity.ps1），让工作区
# 里的 exe 也能直接双击；本脚本保留为备用入口，并在发布前顺手修一次源文件标签。
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Name = 'legado-desktop',
    [string]$DestDir = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not $DestDir) {
    $DestDir = Join-Path $env:LOCALAPPDATA 'Programs\legado'
}

if (-not (Test-Path $Source)) {
    Write-Error "源文件不存在: $Source"
    exit 1
}

# 顺手把源产物也修成 Medium 标签：这样工作区里的 bin/<name>.exe 本身就能双击，
# 不必每次绕到发布目录。标签已正确时脚本会自行跳过，不需要管理员权限。
& (Join-Path $PSScriptRoot 'fix-integrity.ps1') -Exe $Source

New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
$dest = Join-Path $DestDir "$Name.exe"
Copy-Item $Source $dest -Force

Write-Host "[publish] 已发布: $dest"

# 目标目录若也带 Low 标签，普通权限双击仍会失败——给出可执行的修正命令。
$aclLines = & icacls $dest
$lowLabel = $aclLines | Where-Object { $_ -match 'Mandatory Label' -and $_ -match 'Low' }
if ($lowLabel) {
    Write-Warning "[publish] 目标仍带 Low 完整性标签，普通权限双击仍会失败。"
    Write-Warning "[publish] 修正: icacls `"$DestDir`" /setintegritylevel (OI)(CI)M"
} else {
    Write-Host "[publish] 完整性标签 OK，可直接双击启动"
}
