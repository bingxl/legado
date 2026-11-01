#Requires -Version 7
<#
.SYNOPSIS
  获取 Puppertino CSS 并接入 index.html（frontend:vendor:puppertino 任务的 Windows 分支）。
  POSIX 分支直接用系统自带 curl/awk/sed；本脚本保证 Windows 上不依赖 Git Bash 工具链。
#>
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot\..\..

New-Item -ItemType Directory -Force -Path 'frontend/public/puppertino' | Out-Null

$css = 'frontend/public/puppertino/puppertino.css'
if (-not (Test-Path $css)) {
    Write-Host 'No bundled Puppertino found. Attempting to fetch from GitHub...'
    try {
        Invoke-WebRequest 'https://raw.githubusercontent.com/codedgar/Puppertino/main/dist/css/full.css' -OutFile $css
        try { Invoke-WebRequest 'https://raw.githubusercontent.com/codedgar/Puppertino/main/LICENSE' -OutFile 'frontend/public/puppertino/LICENSE' } catch {}
        Write-Host 'Puppertino CSS downloaded to frontend/public/puppertino/puppertino.css'
    } catch {
        Write-Host 'Warning: Could not fetch Puppertino CSS. Proceeding without download since template may bundle it.'
    }
} else {
    Write-Host 'Using bundled Puppertino at frontend/public/puppertino/puppertino.css'
}

# Ensure index.html includes Puppertino CSS and button classes
$index = 'frontend/index.html'
if (Test-Path $index) {
    $html = Get-Content $index -Raw
    $orig = $html
    if ($html -notmatch 'href="/puppertino/puppertino\.css"') {
        # 在 style.css 链接之后插入 Puppertino link
        $html = $html -replace '(href="/style\.css"/?>)', "`$1`n    <link rel=`"stylesheet`" href=`"/puppertino/puppertino.css`"/>"
    }
    # 默认 .btn 替换为 Puppertino 主按钮样式
    $html = $html -replace 'class="btn"', 'class="p-btn p-prim-col"'
    if ($html -ne $orig) { Set-Content $index $html -NoNewline }
}
