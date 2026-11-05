#Requires -Version 7.0
<#
.SYNOPSIS
    编译无控制台入口 dsh-luncher.exe 和安装包（Inno Setup 6），可选再打一个免安装 zip。

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Portable
#>
[CmdletBinding()]
param([switch]$Portable)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# 版本号以 .iss 为准，写到 version.txt 供程序自检更新用
$issText = Get-Content (Join-Path $PSScriptRoot 'dsh-luncher.iss') -Raw
$match = [regex]::Match($issText, '#define AppVersion "([^"]+)"')
if (-not $match.Success) { throw '无法从 dsh-luncher.iss 读取 AppVersion' }
$appVersion = $match.Groups[1].Value
Set-Content -Path (Join-Path $root 'version.txt') -Value $appVersion -Encoding utf8 -NoNewline
Write-Host "版本号：$appVersion" -ForegroundColor Cyan

# 1. 编译无控制台入口（双击不闪 PowerShell 窗口）
$csc = @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $csc) {
    throw '找不到 csc.exe（.NET Framework 4 自带），无法编译 dsh-luncher.exe'
}

$exe = Join-Path $root 'dsh-luncher.exe'
Remove-Item $exe -Force -ErrorAction SilentlyContinue
& $csc /nologo /codepage:65001 /target:winexe /optimize+ "/win32icon:$root\launcher.ico" "/out:$exe" (Join-Path $PSScriptRoot 'launcher.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { throw "编译 dsh-luncher.exe 失败：$LASTEXITCODE" }
Write-Host ("入口程序：{0} ({1:N0} 字节)" -f $exe, (Get-Item $exe).Length) -ForegroundColor Green

# 2. 编译安装包
$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
    throw '找不到 ISCC.exe。先安装 Inno Setup 6：winget install JRSoftware.InnoSetup'
}

Write-Host "使用编译器：$iscc" -ForegroundColor Cyan
& $iscc (Join-Path $PSScriptRoot 'dsh-luncher.iss')
if ($LASTEXITCODE -ne 0) { throw "编译失败，退出码 $LASTEXITCODE" }

$setup = Get-ChildItem (Join-Path $PSScriptRoot 'Output') -Filter '*.exe' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host ("安装包：{0} ({1:N2} MB)" -f $setup.FullName, ($setup.Length / 1MB)) -ForegroundColor Green

if ($Portable) {
    $stage = Join-Path $env:TEMP ('dsh-luncher-portable-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    foreach ($name in @('dsh-luncher.exe', 'dsh-luncher.ps1', 'dsh-luncher.cmd', 'ui.xaml', 'launcher.ico', 'README.md', 'LICENSE', 'version.txt')) {
        Copy-Item (Join-Path $root $name) $stage
    }

    Copy-Item (Join-Path $root 'themes') $stage -Recurse

    $zip = Join-Path (Join-Path $PSScriptRoot 'Output') 'dsh-luncher-portable.zip'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
    Remove-Item $stage -Recurse -Force

    Write-Host ("免安装包：{0} ({1:N2} MB)" -f $zip, ((Get-Item $zip).Length / 1MB)) -ForegroundColor Green
}
