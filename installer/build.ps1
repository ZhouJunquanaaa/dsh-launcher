#Requires -Version 7.0
<#
.SYNOPSIS
    编译安装包（Inno Setup 6），可选再打一个免安装 zip。

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Portable
#>
[CmdletBinding()]
param([switch]$Portable)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

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

    foreach ($name in @('dsh-luncher.ps1', 'dsh-luncher.cmd', 'ui.xaml', 'launcher.ico', 'README.md', 'LICENSE')) {
        Copy-Item (Join-Path $root $name) $stage
    }

    $zip = Join-Path (Join-Path $PSScriptRoot 'Output') 'dsh-luncher-portable.zip'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
    Remove-Item $stage -Recurse -Force

    Write-Host ("免安装包：{0} ({1:N2} MB)" -f $zip, ((Get-Item $zip).Length / 1MB)) -ForegroundColor Green
}
