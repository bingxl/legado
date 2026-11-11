# 修正 Windows 构建产物的完整性标签（Mandatory Integrity Control）。
#
# 背景：仓库位于 C:\Users\<用户>\work 下，work 目录上有一条**显式**的
# "Mandatory Label\Low Mandatory Level:(OI)(CI)(NW)"，子目录和文件全部继承它。
# Windows 创建进程时会把新进程的令牌降到**镜像文件**的完整性级别，因此普通
# 权限双击工作区里的 exe 得到的是 Low IL 进程：
#   * 写不了 %LOCALAPPDATA% 下的 app.log / 数据库（NO_WRITE_UP）；
#   * WebView2 创建 controller 失败，报 800700aa "The requested resource is in use"；
#   * 表现为「双击没反应，只有以管理员身份运行才打得开」。
# 以管理员运行得到 High IL，绕过了上述限制，所以看起来像「程序要求管理员权限」，
# 实际与 exe 的 UAC manifest（asInvoker）、签名、数据目录 ACL 都无关。
#
# 修复只针对产物文件本身设一条**显式 Medium 标签**，不需要管理员权限，也不需要
# 改动整个 work 目录的标签（那会削弱工作区的写保护）。
#
# 每次构建都要重设一次：go build -o 覆盖文件通常保留 ACL，但删除重建、签名工具
# 替换文件、或重新 clone 时，文件会重新继承 Low 标签。
param(
    [Parameter(Mandatory = $true)][string]$Exe
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not (Test-Path -LiteralPath $Exe)) {
    # 交叉编译 / CI 上可能没有这个产物，不要因此让构建失败。
    Write-Host "[il] target not found, skipping: $Exe"
    exit 0
}

$before = (& icacls "$Exe" 2>&1 | Select-String 'Mandatory Label') -join ' '
if ($before -notmatch 'Low Mandatory Level') {
    Write-Host "[il] integrity label OK (no Low label): $Exe"
    exit 0
}

Write-Host "[il] fixing Low -> Medium integrity label: $Exe"
& icacls "$Exe" /setintegritylevel M 2>&1 | ForEach-Object { Write-Host "[il]   $_" }
if ($LASTEXITCODE -ne 0) {
    # 不阻塞构建：还有 task publish（把 exe 复制到工作区外）这条备用路径。
    Write-Warning "[il] icacls failed (exit $LASTEXITCODE). Run once as administrator, or use 'task publish'."
    exit 0
}

$after = (& icacls "$Exe" 2>&1 | Select-String 'Mandatory Label') -join ' '
Write-Host "[il] now: $after"
