#Requires -Version 7.0
<#
    dsh-luncher（GUI）
    - 为每个实例维护独立的 DSH_HOME，互不污染配置/会话/凭证
    - 通过 npm --prefix 把指定版本的 dsh 装进 versions\ 目录，不影响全局 npm / nvm
    - 启动 dsh web 后轮询端口，就绪即打开浏览器
#>
[CmdletBinding()]
param([switch]$SmokeTest, [switch]$Import)

$ErrorActionPreference = 'Stop'

# 必须在加载 WPF 之前设 AppUserModelID：WPF 一加载就会建隐藏窗口，
# 之后进程的 AUMID 就锁定成 pwsh 的了，任务栏会一直显示 PowerShell 图标
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct PROPERTYKEY {
    public Guid fmtid;
    public uint pid;
}

[StructLayout(LayoutKind.Explicit)]
public struct PROPVARIANT {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pointerValue;
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
    void GetCount(out uint cProps);
    void GetAt(uint iProp, out PROPERTYKEY pkey);
    void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
    void Commit();
}

public static class DshTaskbar {
    [DllImport("shell32.dll")]
    static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, out IPropertyStore store);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadImage(IntPtr hinst, string name, uint type, int cx, int cy, uint load);

    public const int WM_SETICON = 0x0080;
    public const uint IMAGE_ICON = 1;
    public const uint LR_LOADFROMFILE = 0x0010;

    // 进程级 AUMID 改不动（pwsh 启动时就定了），但可以给单个窗口挂 AUMID，
    // 任务栏据此分组并取对应快捷方式的图标和名字。
    public static bool SetWindowAppId(IntPtr hwnd, string appId) {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0 || store == null) return false;

        var key = new PROPERTYKEY();
        key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        key.pid = 5;

        var pv = new PROPVARIANT();
        pv.vt = 31;
        pv.pointerValue = Marshal.StringToCoTaskMemUni(appId);
        try {
            store.SetValue(ref key, ref pv);
            store.Commit();
        } finally {
            Marshal.FreeCoTaskMem(pv.pointerValue);
            Marshal.ReleaseComObject(store);
        }
        return true;
    }
}
'@ -ErrorAction Stop
} catch { }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Root = $PSScriptRoot

# 数据目录：安装器写下的 data-dir.txt 优先；没有就放在程序旁边（便携模式）
$dataFile = Join-Path $script:Root 'data-dir.txt'
$script:DataRoot = $script:Root
if (Test-Path $dataFile) {
    $configured = Get-Content $dataFile -Raw -ErrorAction SilentlyContinue
    if ($configured) {
        $configured = $configured.Trim()
        if ($configured) { $script:DataRoot = $configured }
    }
}

$script:SettingsPath  = Join-Path $script:DataRoot 'settings.json'
$script:LegacyConfig  = Join-Path $script:DataRoot 'launcher.json'
$script:VersionsRoot  = Join-Path $script:DataRoot 'versions'
$script:InstancesRoot = Join-Path $script:DataRoot 'instances'
$script:LogsRoot      = Join-Path $script:DataRoot 'logs'
$script:SeedFiles    = @('settings.yaml', '.credentials.yaml', '.env')
$script:Running      = @{}
$script:Install      = $null
$script:Tail         = @()
$script:Registry     = $null
$script:LastHash     = ''
$script:Headless     = $false

foreach ($d in @($script:VersionsRoot, $script:InstancesRoot, $script:LogsRoot)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ------------------------------------------------------------------ 配置

$script:Registries = @(
    [pscustomobject]@{ Name = 'npm 官方'; Url = 'https://registry.npmjs.org/' }
    [pscustomobject]@{ Name = '淘宝 npmmirror'; Url = 'https://registry.npmmirror.com/' }
    [pscustomobject]@{ Name = '腾讯云'; Url = 'https://mirrors.cloud.tencent.com/npm/' }
    [pscustomobject]@{ Name = '华为云'; Url = 'https://repo.huaweicloud.com/repository/npm/' }
)

function Get-RegistryUrl {
    if ($script:Cfg -and $script:Cfg.registry) { return $script:Cfg.registry }
    return 'https://registry.npmjs.org/'
}

function Get-RegistryLabel ([string]$url) {
    foreach ($item in $script:Registries) {
        if ($item.Url -eq $url) { return $item.Name }
    }
    return $url
}

function Resolve-RegistryInput ([string]$text) {
    if (-not $text) { return $null }
    $text = $text.Trim()
    if ($text -match '^https?://') { return $text }
    foreach ($item in $script:Registries) {
        if ($item.Name -eq $text) { return $item.Url }
    }
    return $null
}

function Update-RegistryHint {
    if (-not $script:TxtRegistryHint) { return }
    $url = Get-RegistryUrl
    $label = Get-RegistryLabel $url
    if ($label -eq $url) {
        $script:TxtRegistryHint.Text = '当前：' + $url
    } else {
        $script:TxtRegistryHint.Text = '当前：' + $label + '  ' + $url
    }
}

function Set-Registry ([string]$url) {
    if (-not $url) { return }
    if ($url -ne $script:Cfg.registry) {
        $script:Cfg.registry = $url
        Save-Config
        Append-Log ('下载源切换为 ' + $url + [Environment]::NewLine)
    }
    Update-RegistryHint
}

function New-DefaultConfig {
    [ordered]@{ version = 2; theme = 'light'; registry = 'https://registry.npmjs.org/' }
}

function Read-Config {
    if (-not (Test-Path $script:SettingsPath)) { return (New-DefaultConfig) }
    try {
        $raw = Get-Content $script:SettingsPath -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        return (New-DefaultConfig)
    }
    $cfg = New-DefaultConfig
    if ($raw.PSObject.Properties['theme'] -and $raw.theme -in @('light', 'dark')) { $cfg.theme = $raw.theme }
    if ($raw.PSObject.Properties['registry'] -and $raw.registry) { $cfg.registry = $raw.registry }
    return $cfg
}

function Save-Config {
    try {
        $dir = Split-Path $script:SettingsPath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $script:Cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $script:SettingsPath -Encoding utf8
    } catch {
        Write-Crash 'Save-Config' $_
        throw
    }
}

# 实例 = instances<名字>{instance.json, home}；列表靠扫描目录得到，不再有中心清单
function Get-Instances {
    if (-not (Test-Path $script:InstancesRoot)) { return @() }
    $list = @()
    foreach ($dir in @(Get-ChildItem $script:InstancesRoot -Directory -ErrorAction SilentlyContinue)) {
        $file = Join-Path $dir.FullName 'instance.json'
        if (-not (Test-Path $file)) { continue }
        try {
            $data = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
            $data | Add-Member -NotePropertyName dir -NotePropertyValue $dir.FullName -Force
            $list += $data
        } catch { }
    }
    return @($list | Sort-Object name)
}

function Get-InstanceDir ([string]$name) {
    return (Join-Path $script:InstancesRoot $name)
}

function Get-SharedHome {
    $path = Join-Path $script:DataRoot 'shared-home'
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    return $path
}

function Get-HomeMode ($inst) {
    if ($inst.homeMode) { return $inst.homeMode }
    if ($inst.shareHome) { return 'shared' }
    return 'own'
}

function Get-InstanceHome ($inst) {
    # own：实例自己的 home；shared：所有共享实例共用；desktop：直接用桌面端的 ~/.dsh
    switch (Get-HomeMode $inst) {
        'desktop' { return (Join-Path $env:USERPROFILE '.dsh') }
        'shared'  { return (Get-SharedHome) }
    }
    if ($inst.dir) { return (Join-Path $inst.dir 'home') }
    return (Join-Path (Get-InstanceDir $inst.name) 'home')
}

function Save-Instance ($inst) {
    $dir = $inst.dir
    if (-not $dir) { $dir = Get-InstanceDir $inst.name }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $payload = [ordered]@{
        name       = $inst.name
        dshVersion = $inst.dshVersion
        port       = $inst.port
        cwd        = $inst.cwd
        notes      = $inst.notes
    }
    if ($inst.bin) { $payload.bin = $inst.bin }
    if ($inst.source) { $payload.source = $inst.source }
    $mode = Get-HomeMode $inst
    if ($mode -ne 'own') { $payload.homeMode = $mode }
    $payload | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir 'instance.json') -Encoding utf8
    return $dir
}

function Remove-InstanceDir ($inst) {
    $dir = if ($inst.dir) { $inst.dir } else { Get-InstanceDir $inst.name }
    if (Test-Path $dir) { Remove-Directory $dir }
}

# ------------------------------------------------------------------ 工具

function Get-NodePath {
    $cmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { throw 'PATH 中找不到 node.exe' }
    return $cmd.Source
}

function New-ThemeDictionary ([string]$name) {
    $file = Join-Path (Join-Path $script:Root 'themes') ($name + '.xaml')
    if (-not (Test-Path $file)) { $file = Join-Path (Join-Path $script:Root 'themes') 'light.xaml' }
    return [System.Windows.Markup.XamlReader]::Parse((Get-Content $file -Raw -Encoding utf8))
}

function Set-Theme ([string]$name) {
    $dictionary = New-ThemeDictionary $name
    $script:Window.Resources.MergedDictionaries.Clear()
    $script:Window.Resources.MergedDictionaries.Add($dictionary)
    $script:Theme = $name
    $button = $script:Window.FindName('btnTheme')
    if ($button) { $button.Content = if ($name -eq 'light') { '深色' } else { '浅色' } }
}

function Invoke-LayoutMigration {
    # 旧布局 launcher.json + homes\<name>\  ->  新布局 instances\<name>\{instance.json, home\}
    if (-not (Test-Path $script:LegacyConfig)) { return }
    try {
        $legacy = Get-Content $script:LegacyConfig -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        return
    }

    foreach ($inst in @($legacy.instances)) {
        if (-not $inst -or -not $inst.name) { continue }
        $dir = Join-Path $script:InstancesRoot $inst.name
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        $payload = [ordered]@{
            name       = $inst.name
            dshVersion = $inst.dshVersion
            port       = $inst.port
            cwd        = $inst.cwd
            notes      = $inst.notes
        }
        if ($inst.bin) { $payload.bin = $inst.bin }
        if ($inst.source) { $payload.source = $inst.source }
        $payload | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir 'instance.json') -Encoding utf8

        $oldHome = $inst.dshHome
        if ($oldHome -and (Test-Path $oldHome)) {
            $newHome = Join-Path $dir 'home'
            if (-not (Test-Path $newHome)) {
                try { Move-Item $oldHome $newHome -Force } catch { }
            }
        }
    }

    $settings = New-DefaultConfig
    if ($legacy.PSObject.Properties['theme'] -and $legacy.theme) { $settings.theme = $legacy.theme }
    if ($legacy.PSObject.Properties['registry'] -and $legacy.registry) { $settings.registry = $legacy.registry }
    $settings | ConvertTo-Json -Depth 5 | Set-Content $script:SettingsPath -Encoding utf8

    Rename-Item $script:LegacyConfig ($script:LegacyConfig + '.migrated') -Force -ErrorAction SilentlyContinue

    # 清掉空的旧 homes 目录
    $oldHomes = Join-Path $script:DataRoot 'homes'
    if ((Test-Path $oldHomes) -and (@(Get-ChildItem $oldHomes -Force -ErrorAction SilentlyContinue).Count -eq 0)) {
        Remove-Item $oldHomes -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DataMigration {
    $hasData = (Test-Path $script:SettingsPath) -or
        (@(Get-ChildItem $script:InstancesRoot -Directory -ErrorAction SilentlyContinue).Count -gt 0) -or
        (Test-Path $script:LegacyConfig)

    if (-not (Test-Path $dataFile) -or $hasData) {
        Invoke-LayoutMigration
        return
    }

    $legacyDirs = @(
        (Join-Path $env:LOCALAPPDATA 'dsh-luncher'),
        (Join-Path $env:LOCALAPPDATA 'dsh-launcher')
    )

    foreach ($legacy in $legacyDirs) {
        if (-not (Test-Path $legacy)) { continue }
        $prompt = '检测到旧数据目录：' + [Environment]::NewLine + $legacy +
            [Environment]::NewLine + [Environment]::NewLine +
            '是否迁移到新的数据目录？' + [Environment]::NewLine + $script:DataRoot +
            [Environment]::NewLine + [Environment]::NewLine +
            '迁移会把已下载的版本和配置搬过去，可能需要几分钟。选「否」则从空目录开始，旧数据原样保留。'
        $answer = [System.Windows.MessageBox]::Show($prompt, '迁移数据', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }

        try {
            if (Test-Path $script:DataRoot) { Remove-Item $script:DataRoot -Recurse -Force -ErrorAction SilentlyContinue }
            $parent = Split-Path $script:DataRoot -Parent
            if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

            # robocopy 能处理超过 260 字符的 node_modules 路径，Move-Item 会失败
            $robocopy = Start-Process -FilePath 'robocopy.exe' -ArgumentList @(
                $legacy, $script:DataRoot, '/E', '/MOVE', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
            ) -Wait -PassThru -WindowStyle Hidden
            if ($robocopy.ExitCode -ge 8) { throw ('robocopy 退出码 ' + $robocopy.ExitCode) }

            if (-not (Test-Path $script:DataRoot)) { New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null }
            if (Test-Path $legacy) { Remove-Item $legacy -Recurse -Force -ErrorAction SilentlyContinue }
        } catch { }
        break
    }

    Invoke-LayoutMigration
}

function Get-AppVersion {
    $file = Join-Path $script:Root 'version.txt'
    if (Test-Path $file) {
        $value = Get-Content $file -Raw -ErrorAction SilentlyContinue
        if ($value) { $value = $value.Trim() }
        if ($value) { return $value }
    }
    return '0.0.0'
}

function Compare-AppVersion ([string]$left, [string]$right) {
    try {
        return ([version]($left -replace '^v', '')).CompareTo([version]($right -replace '^v', ''))
    } catch { return 0 }
}

function Update-AppVersionLabel {
    if (-not $script:BtnAppUpdate) { return }
    $current = Get-AppVersion
    if ($script:LatestRelease -and (Compare-AppVersion $script:LatestRelease.tag_name $current) -gt 0) {
        $script:BtnAppUpdate.Content = '更新到 ' + $script:LatestRelease.tag_name
        $script:BtnAppUpdate.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'AccentBrush')
    } else {
        $script:BtnAppUpdate.Content = 'v' + $current
        $script:BtnAppUpdate.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'MutedBrush')
    }
}

function Check-AppUpdate ([switch]$Silent) {
    $current = Get-AppVersion
    try {
        $script:LatestRelease = Invoke-RestMethod 'https://api.github.com/repos/ZhouJunquanaaa/dsh-launcher/releases/latest' -Headers @{ 'User-Agent' = 'dsh-luncher'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 20
    } catch {
        if (-not $Silent) { [System.Windows.MessageBox]::Show('检查更新失败：' + $_.Exception.Message, '检查更新') | Out-Null }
        return
    }

    Update-AppVersionLabel
    $latest = $script:LatestRelease.tag_name
    if ((Compare-AppVersion $latest $current) -le 0) {
        if (-not $Silent) { [System.Windows.MessageBox]::Show('已是最新版本 v' + $current, '检查更新') | Out-Null }
        return
    }

    Append-Log ('发现新版本 ' + $latest + '（当前 v' + $current + '）' + [Environment]::NewLine)
    if (-not $Silent) { Start-AppUpdate }
}

function Start-AppUpdate {
    $release = $script:LatestRelease
    if (-not $release) { return }
    $current = Get-AppVersion

    $answer = [System.Windows.MessageBox]::Show(
        '发现新版本 ' + $release.tag_name + '（当前 v' + $current + '）。' + [Environment]::NewLine + [Environment]::NewLine +
        '现在下载并安装？装完会自动重新打开。',
        '检查更新', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    $asset = @($release.assets | Where-Object { $_.name -like '*.exe' }) | Select-Object -First 1
    if (-not $asset) {
        [System.Windows.MessageBox]::Show('该版本没有提供安装包。', '检查更新') | Out-Null
        return
    }

    $target = Join-Path $env:TEMP $asset.name
    Append-Log ('下载 ' + $asset.name + ' ...' + [Environment]::NewLine)
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $target -TimeoutSec 300 -UseBasicParsing
    } catch {
        [System.Windows.MessageBox]::Show('下载失败：' + $_.Exception.Message, '检查更新') | Out-Null
        return
    }

    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/TASKS=desktopicon', ('/DIR="' + $script:Root + '"'))
    if (Test-Path (Join-Path $script:Root 'data-dir.txt')) {
        $arguments += ('/DATADIR="' + $script:DataRoot + '"')
    }

    $exePath = Join-Path $script:Root 'dsh-luncher.exe'
    $quoted = ($arguments | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $helper = 'Start-Process -FilePath ''' + $target + ''' -ArgumentList @(' + $quoted + ') -Wait; Start-Process -FilePath ''' + $exePath + ''''
    Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-Command', $helper) -WindowStyle Hidden

    Append-Log ('已启动安装程序，程序即将退出。' + [Environment]::NewLine)
    Start-Sleep -Milliseconds 400
    $script:Window.Close()
}

function Set-InstanceHomeMode ($inst, [string]$mode) {
    if ((Get-HomeMode $inst) -eq $mode) { return }

    $target = switch ($mode) {
        'desktop' { Join-Path $env:USERPROFILE '.dsh' }
        'shared'  { Join-Path $script:DataRoot 'shared-home' }
        default   { Join-Path (Get-InstanceDir $inst.name) 'home' }
    }

    $message = '把「' + $inst.name + '」的配置来源改成 ' + $(switch ($mode) {
        'desktop' { '桌面端（~/.dsh）' }
        'shared'  { '共享配置' }
        default   { '独立配置' }
    }) + '？' + [Environment]::NewLine + [Environment]::NewLine +
    '之后它的 DSH_HOME 指向：' + [Environment]::NewLine + $target +
    [Environment]::NewLine + [Environment]::NewLine +
    '原来的目录会保留，不会删除。'

    $answer = [System.Windows.MessageBox]::Show($message, '配置来源', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    $inst | Add-Member -NotePropertyName homeMode -NotePropertyValue $mode -Force
    $inst | Add-Member -NotePropertyName shareHome -NotePropertyValue $false -Force
    Save-Instance $inst | Out-Null
    Refresh-InstanceList
    Append-Log ('实例 ' + $inst.name + ' 配置来源改为 ' + $mode + [Environment]::NewLine)
}

function Show-InputDialog ([string]$title, [string]$label, [string]$default) {
    $dlg = [System.Windows.Window]::new()
    $dlg.Title = $title
    $dlg.Width = 420
    $dlg.SizeToContent = 'Height'
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.ResizeMode = 'NoResize'
    $dlg.Resources.MergedDictionaries.Add((New-ThemeDictionary $script:Theme))
    $dlg.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'WindowBrush')
    $dlg.SetResourceReference([System.Windows.Window]::ForegroundProperty, 'TextBrush')
    $dlg.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI')

    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Margin = [System.Windows.Thickness]::new(18)

    $text = [System.Windows.Controls.TextBlock]::new()
    $text.Text = $label
    $text.TextWrapping = 'Wrap'
    $text.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $panel.Children.Add($text) | Out-Null

    $box = [System.Windows.Controls.TextBox]::new()
    $box.Text = $default
    $panel.Children.Add($box) | Out-Null

    $buttons = [System.Windows.Controls.StackPanel]::new()
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)

    $ok = [System.Windows.Controls.Button]::new()
    $ok.Content = '确定'
    $ok.Width = 90
    $ok.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $ok.IsDefault = $true
    $ok.Style = $script:Window.FindResource('PrimaryButton')
    $cancel = [System.Windows.Controls.Button]::new()
    $cancel.Content = '取消'
    $cancel.Width = 90
    $cancel.IsCancel = $true
    $cancel.Style = $script:Window.FindResource('SecondaryButton')

    $buttons.Children.Add($ok) | Out-Null
    $buttons.Children.Add($cancel) | Out-Null
    $panel.Children.Add($buttons) | Out-Null

    $dlg.Content = $panel
    $script:InputResult = $null
    $script:InputBox = $box
    $script:InputWindow = $dlg

    $ok.Add_Click({
        $script:InputResult = $script:InputBox.Text.Trim()
        $script:InputWindow.Close()
    })

    $dlg.ShowDialog() | Out-Null
    return $script:InputResult
}

function Edit-InstancePort ($inst) {
    $current = [string]$inst.port
    $entered = Show-InputDialog ('修改端口 - ' + $inst.name) '给这个实例换一个监听端口（1-65535）：' $current
    if (-not $entered) { return }

    $port = 0
    if (-not [int]::TryParse($entered, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        [System.Windows.MessageBox]::Show('端口无效，请输入 1-65535 之间的数字。', '修改端口') | Out-Null
        return
    }

    if ($port -ne [int]$inst.port) {
        $others = @(Get-Instances | Where-Object { $_.name -ne $inst.name -and [int]$_.port -eq $port })
        if ($others.Count -gt 0) {
            [System.Windows.MessageBox]::Show('端口 ' + $port + ' 已被实例「' + $others[0].name + '」占用。', '修改端口') | Out-Null
            return
        }
        if (-not (Test-PortFree $port)) {
            $answer = [System.Windows.MessageBox]::Show(
                '端口 ' + $port + ' 现在被别的进程占用着。' + [Environment]::NewLine + [Environment]::NewLine + '仍然保存这个端口吗？',
                '修改端口', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
        }
    }

    $inst | Add-Member -NotePropertyName port -NotePropertyValue $port -Force
    Save-Instance $inst | Out-Null
    Refresh-InstanceList
    Append-Log ('实例 ' + $inst.name + ' 端口改为 ' + $port + [Environment]::NewLine)
}

function Get-NpmPath {
    foreach ($name in @('npm.cmd', 'npm.exe', 'npm')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    throw 'PATH 中找不到 npm，请确认已安装 Node.js。'
}

function Test-PortOpen ([int]$port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $port)
        if ($task.Wait(200)) { return $client.Connected }
        return $false
    } catch { return $false } finally { $client.Dispose() }
}

function Test-PortFree ([int]$port) {
    try {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}

function Get-FreePort {
    $used = @(Get-Instances | ForEach-Object { [int]$_.port })
    for ($p = 8889; $p -lt 8999; $p++) {
        if ($used -contains $p) { continue }
        if (Test-PortFree $p) { return $p }
    }
    return 8889
}

function Get-BinPath ([string]$version) {
    return (Join-Path $script:VersionsRoot (Join-Path $version 'node_modules\@deepseek-ai\dsh\lib\bin.js'))
}

function Get-InstanceBin ($inst) {
    if ($inst.bin -and (Test-Path $inst.bin)) { return $inst.bin }
    $derived = Get-BinPath $inst.dshVersion
    if (Test-Path $derived) { return $derived }
    return $null
}

function Seed-Home ([string]$homePath) {
    $legacy = Join-Path $env:USERPROFILE '.dsh'
    if (-not (Test-Path $legacy)) { return }
    foreach ($f in $script:SeedFiles) {
        $src = Join-Path $legacy $f
        $dst = Join-Path $homePath $f
        if ((Test-Path $src) -and -not (Test-Path $dst)) { Copy-Item $src $dst -Force }
    }
}

# ------------------------------------------------------------------ 版本

function Get-InstalledVersions {
    $rows = @()
    foreach ($d in @(Get-ChildItem $script:VersionsRoot -Directory -ErrorAction SilentlyContinue)) {
        $pkg = Join-Path $d.FullName 'node_modules\@deepseek-ai\dsh\package.json'
        if (-not (Test-Path $pkg)) { continue }
        $v = (Get-Content $pkg -Raw -Encoding utf8 | ConvertFrom-Json).version
        # 只有 package.json 没有 libin.js 说明装了一半（中断、磁盘满、被占用），标出来
        $bin = Join-Path $d.FullName 'node_modules\@deepseek-ai\dsh\lib\bin.js'
        $ok = Test-Path $bin
        $rows += [pscustomobject]@{
            Version = $v
            Source  = 'versions\'
            Display = $(if ($ok) { $v } else { $v + '（不完整）' })
            Ok      = $ok
        }
    }
    return @($rows | Sort-Object Version -Descending)
}

function Get-RegistryInfo {
    $base = (Get-RegistryUrl).TrimEnd('/')
    $m = Invoke-RestMethod ($base + '/@deepseek-ai%2Fdsh') -TimeoutSec 25
    return [pscustomobject]@{
        Latest   = $m.'dist-tags'.latest
        Next     = $m.'dist-tags'.next
        Alpha    = $m.'dist-tags'.alpha
        Versions = @($m.versions.PSObject.Properties.Name)
    }
}

# ------------------------------------------------------------------ 日志

function Append-Log ([string]$text) {
    if (-not $text) { return }
    $script:TxtLog.AppendText($text)
    $script:TxtLog.ScrollToEnd()
}

function Read-OneLog ($entry) {
    if (-not $entry.Path) { return }
    if (-not (Test-Path $entry.Path)) { return }
    try {
        $fs = [System.IO.File]::Open($entry.Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $fs.Seek($entry.Pos, [System.IO.SeekOrigin]::Begin) | Out-Null
            $sr = [System.IO.StreamReader]::new($fs)
            $text = $sr.ReadToEnd()
            $entry.Pos = $fs.Position
            $sr.Dispose()
        } finally { $fs.Dispose() }
        if ($text) { Append-Log $text }
    } catch { }
}

function Read-NewLog {
    foreach ($entry in @($script:Tail)) { Read-OneLog $entry }
}

function Write-Crash ([string]$where, $err) {
    try {
        $detail = if ($err -is [System.Management.Automation.ErrorRecord]) { $err.Exception } else { $err }
        $text = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  [' + $where + ']  ' +
            $detail.GetType().Name + ': ' + $detail.Message + [Environment]::NewLine +
            $detail.StackTrace + [Environment]::NewLine + [Environment]::NewLine
        Add-Content -Path (Join-Path $script:LogsRoot 'crash.log') -Value $text -Encoding utf8
    } catch { }
}

function Show-Error ([string]$where, $err) {
    Write-Crash $where $err
    $msg = if ($err -is [System.Management.Automation.ErrorRecord]) { $err.Exception.Message } else { $err.Message }
    [System.Windows.MessageBox]::Show(
        $msg + [Environment]::NewLine + [Environment]::NewLine + '详情已写入 logs\crash.log',
        '出错了') | Out-Null
}

# ------------------------------------------------------------------ 实例

function Start-Instance ($inst) {
    if ($script:Running[$inst.name]) {
        [System.Windows.MessageBox]::Show('该实例已在运行。', '提示') | Out-Null
        return
    }
    $sourceDir = $inst.source
    $bin = $null
    $entry = $null
    if ($sourceDir) {
        $entry = Join-Path $sourceDir 'apps\cli\src\bin.ts'
        if (-not (Test-Path $entry)) {
            [System.Windows.MessageBox]::Show('源码目录缺少 apps\cli\src\bin.ts：' + [Environment]::NewLine + $sourceDir, '源码无效') | Out-Null
            return
        }
        if (-not (Test-Path (Join-Path $sourceDir 'node_modules'))) {
            [System.Windows.MessageBox]::Show('源码目录还没有依赖，请先执行：' + [Environment]::NewLine + 'pnpm install' + [Environment]::NewLine + 'pnpm run build', '依赖缺失') | Out-Null
            return
        }
    } else {
        $bin = Get-InstanceBin $inst
        if (-not $bin) {
            $expected = Get-BinPath $inst.dshVersion
            $message = '版本 ' + $inst.dshVersion + ' 的 dsh 没有装好（缺少 lib\bin.js）。' +
                [Environment]::NewLine + [Environment]::NewLine +
                '期望路径：' + [Environment]::NewLine + $expected +
                [Environment]::NewLine + [Environment]::NewLine +
                '请在右侧重新安装该版本；如果列表里显示「不完整」，先删掉再装。'
            [System.Windows.MessageBox]::Show($message, '缺少版本') | Out-Null
            return
        }
    }

    $homePath = Get-InstanceHome $inst

    # 同一份 home 被两个进程同时写会互相抢存储，先提醒
    $conflicts = @()
    foreach ($runningName in @($script:Running.Keys)) {
        $other = Get-Instances | Where-Object { $_.name -eq $runningName } | Select-Object -First 1
        if ($other -and (Get-InstanceHome $other) -eq $homePath) { $conflicts += $runningName }
    }
    if ($conflicts.Count -gt 0) {
        $answer = [System.Windows.MessageBox]::Show(
            '实例「' + ($conflicts -join '、') + '」正在使用同一份配置目录：' + [Environment]::NewLine + $homePath +
            [Environment]::NewLine + [Environment]::NewLine +
            '两个 dsh 进程同时写同一份存储可能互相覆盖，出现「无法保存」之类的错误。' +
            [Environment]::NewLine + [Environment]::NewLine + '仍然启动吗？',
            '共享配置冲突', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }

    if (-not (Test-Path $homePath)) {
        New-Item -ItemType Directory -Path $homePath -Force | Out-Null
        Seed-Home $homePath
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $base = Join-Path $script:LogsRoot ($inst.name + '-' + $stamp)
    $outLog = $base + '.out.log'
    $errLog = $base + '.err.log'
    $node = Get-NodePath
    $port = [int]$inst.port

    # 端口被占用：如果是上次没退干净的同一个版本，直接清掉；否则明确报错
    if (-not (Test-PortFree $port)) {
        $owner = $null
        try {
            $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop | Select-Object -First 1
            if ($conn) {
                $owner = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $conn.OwningProcess) -ErrorAction SilentlyContinue
            }
        } catch { }

        $isOurs = $owner -and $owner.CommandLine -and $owner.CommandLine.Contains($inst.dshVersion)
        if ($isOurs) {
            try { taskkill /PID $owner.ProcessId /T /F 2>&1 | Out-Null } catch { }
            Start-Sleep -Milliseconds 900
        }

        if (-not (Test-PortFree $port)) {
            $detail = if ($owner) { 'PID ' + $owner.ProcessId + '  ' + $owner.Name } else { '未知进程' }
            [System.Windows.MessageBox]::Show(
                '端口 ' + $port + ' 已被占用（' + $detail + '）。' + [Environment]::NewLine + [Environment]::NewLine +
                '请结束该进程，或用「新增实例」给这个版本换一个端口。',
                '端口被占用') | Out-Null
            return
        }
    }

    if ($sourceDir) {
        $argList = @('--import', 'tsx/esm', $entry, 'web', '--port', "$port", '--no-open')
        $workDir = $sourceDir
    } else {
        $argList = @($bin, 'web', '--port', "$port", '--no-open')
        $workDir = if ($inst.cwd -and (Test-Path $inst.cwd)) { $inst.cwd } else { $script:Root }
    }

    $proc = Start-Process -FilePath $node -ArgumentList $argList -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden -PassThru -Environment @{ DSH_HOME = $homePath; DSH_LAUNCHER_INSTANCE = $inst.name } -WorkingDirectory $workDir

    $script:Running[$inst.name] = @{
        Process = $proc
        Port    = $port
        Ready   = $false
        Url     = ''
        Log     = $outLog
        ErrLog  = $errLog
        Home    = $homePath
    }
    $script:Tail = @(
        @{ Path = $outLog; Pos = 0 },
        @{ Path = $errLog; Pos = 0 }
    )
    $script:TxtLog.Clear()
    $script:TxtLogPath.Text = $outLog
    Append-Log ('启动 ' + $inst.name + '  (' + $inst.dshVersion + ')' + [Environment]::NewLine)
    Append-Log ('DSH_HOME = ' + $homePath + [Environment]::NewLine)
    Append-Log ('端口     = ' + $port + [Environment]::NewLine + [Environment]::NewLine)
    Refresh-InstanceList
}

function Stop-Instance ([string]$name) {
    $r = $script:Running[$name]
    if (-not $r) { return }
    try { & taskkill /PID $r.Process.Id /T /F 2>&1 | Out-Null } catch { }
    $script:Running.Remove($name)
    Append-Log ([Environment]::NewLine + '已停止 ' + $name + [Environment]::NewLine)
    Refresh-InstanceList
}

function Get-SelectedInstance {
    $row = $script:LstInstances.SelectedItem
    if (-not $row) { return $null }
    return (Get-Instances | Where-Object { $_.name -eq $row.Name } | Select-Object -First 1)
}

# ------------------------------------------------------------------ 刷新

function Refresh-InstanceList {
    $selected = $null
    if ($script:LstInstances.SelectedItem) { $selected = $script:LstInstances.SelectedItem.Name }

    $rows = @()
    foreach ($inst in (Get-Instances)) {
        $status = '已停止'
        $r = $script:Running[$inst.name]
        if ($r) {
            if ($r.Process.HasExited) { $status = '已退出' }
            elseif ($r.Ready) { $status = '运行中' }
            else { $status = '启动中' }
        }
        $label = if ($inst.source) { '源码 ' + $inst.dshVersion } else { $inst.dshVersion }
        switch (Get-HomeMode $inst) {
            'shared'  { $label = $label + '（共享）' }
            'desktop' { $label = $label + '（桌面端）' }
        }
        $rows += [pscustomobject]@{
            Name    = $inst.name
            Version = $label
            Port    = $inst.port
            Status  = $status
            Home    = (Get-InstanceHome $inst)
        }
    }
    $script:LstInstances.ItemsSource = $rows
    if ($selected) {
        foreach ($row in $rows) {
            if ($row.Name -eq $selected) { $script:LstInstances.SelectedItem = $row; break }
        }
    }
    # 重建列表会清空选中项，这里补回第一行，避免“启动”按钮点了没反应
    if (-not $script:LstInstances.SelectedItem -and $rows.Count -gt 0) {
        $script:LstInstances.SelectedIndex = 0
    }
    $script:LastHash = ($rows | ForEach-Object { $_.Name + ':' + $_.Status }) -join '|'
}

function Refresh-VersionList {
    $rows = @(Get-InstalledVersions)
    $script:LstVersions.ItemsSource = $rows
    $installed = @($rows | ForEach-Object { $_.Version })

    $items = @()
    if ($script:Registry) {
        foreach ($v in ($script:Registry.Versions | Sort-Object -Descending)) {
            if ($installed -contains $v) { continue }
            $tag = ''
            if ($v -eq $script:Registry.Latest) { $tag = '  (latest)' }
            elseif ($v -eq $script:Registry.Next) { $tag = '  (next)' }
            elseif ($v -eq $script:Registry.Alpha) { $tag = '  (alpha)' }
            $items += ($v + $tag)
        }
    }
    $script:CmbAvailable.ItemsSource = $items
    if ($items.Count -gt 0) { $script:CmbAvailable.SelectedIndex = 0 }

    if ($script:Registry) {
        $script:LblLatest.Text = '最新版本：' + $script:Registry.Latest
    }
}

# ------------------------------------------------------------------ 安装

function Install-Version ([string]$version) {
    if ($script:Install) {
        [System.Windows.MessageBox]::Show('已有安装任务在进行。', '提示') | Out-Null
        return
    }
    $target = Join-Path $script:VersionsRoot $version
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $outLog = Join-Path $script:LogsRoot ('install-' + $version + '.out.log')
    $errLog = Join-Path $script:LogsRoot ('install-' + $version + '.err.log')

    # 注意：不能写成 @('i','-g','@deepseek-ai/dsh@' + $version, ...) —— 数组字面量里的 + 会被拆成两个元素
    $npm = Get-NpmPath
    $spec = '@deepseek-ai/dsh@' + $version
    $registry = Get-RegistryUrl
    $proc = Start-Process -FilePath $npm -ArgumentList @('i', '-g', $spec, '--prefix', $target, '--registry', $registry, '--no-audit', '--no-fund') -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden -PassThru

    $script:Install = @{ Process = $proc; Version = $version; Log = $outLog }
    $script:Tail = @(
        @{ Path = $outLog; Pos = 0 },
        @{ Path = $errLog; Pos = 0 }
    )
    $script:TxtLog.Clear()
    $script:TxtLogPath.Text = $log
    Append-Log ('npm install @deepseek-ai/dsh@' + $version + ' -> ' + $target + [Environment]::NewLine)
    $script:TxtInstallState.Text = '正在安装 ' + $version + ' ...'
    $script:BtnInstall.IsEnabled = $false
}

# ------------------------------------------------------------------ 删除版本

function Get-DirSize ([string]$path) {
    if (-not $path -or -not (Test-Path $path)) { return [long]0 }
    $sum = [long]0
    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($path, '*', [System.IO.SearchOption]::AllDirectories)) {
            try { $sum += ([System.IO.FileInfo]::new($file)).Length } catch { }
        }
    } catch { }
    return $sum
}

function Format-Size ([long]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return ('{0} B' -f $bytes)
}

function Remove-Directory ([string]$path) {
    if (-not $path -or -not (Test-Path $path)) { return $true }
    try { [System.IO.Directory]::Delete($path, $true); return $true }
    catch {
        try { Remove-Item $path -Recurse -Force -ErrorAction Stop; return $true }
        catch { return $false }
    }
}

function Get-VersionUsage ([string]$version) {
    $all = @(Get-Instances | Where-Object { $_.dshVersion -eq $version })
    return [pscustomobject]@{
        Npm    = @($all | Where-Object { -not $_.source })
        Source = @($all | Where-Object { $_.source })
    }
}

function Show-RemoveVersionDialog ([string]$version, [long]$versionSize, $npmInstances, $sourceInstances, [long]$homeSize, [long]$sourceSize) {
    $dlg = [System.Windows.Window]::new()
    $dlg.Title = '删除版本 ' + $version
    $dlg.Width = 580
    $dlg.SizeToContent = 'Height'
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Resources.MergedDictionaries.Add((New-ThemeDictionary $script:Theme))
    $dlg.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'WindowBrush')
    $dlg.SetResourceReference([System.Windows.Window]::ForegroundProperty, 'TextBrush')
    $dlg.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI')
    $dlg.ResizeMode = 'NoResize'

    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Margin = [System.Windows.Thickness]::new(18)

    $title = [System.Windows.Controls.TextBlock]::new()
    $title.Text = '删除版本 ' + $version
    $title.FontSize = 16
    $title.FontWeight = 'SemiBold'
    $title.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $panel.Children.Add($title) | Out-Null

    $dirText = [System.Windows.Controls.TextBlock]::new()
    $dirText.Text = '版本目录：versions\' + $version + '（' + (Format-Size $versionSize) + '）'
    $dirText.TextWrapping = 'Wrap'
    $dirText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'MutedBrush')
    $dirText.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $panel.Children.Add($dirText) | Out-Null

    # 用 TextBlock 承载文字：CheckBox 的字符串 Content 会把下划线当成访问键
    $chkInstances = [System.Windows.Controls.CheckBox]::new()
    $chkInstances.IsEnabled = ($npmInstances.Count -gt 0)
    $chkInstances.IsChecked = ($npmInstances.Count -gt 0)
    $chkInstances.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $instText = [System.Windows.Controls.TextBlock]::new()
    $instText.TextWrapping = 'Wrap'
    if ($npmInstances.Count -gt 0) {
        $names = ($npmInstances | ForEach-Object { $_.name }) -join '、'
        $instText.Text = '同时删除 ' + $npmInstances.Count + ' 个 npm 实例（' + $names + '）及其配置目录（' + (Format-Size $homeSize) + '）'
    } else {
        $instText.Text = '没有 npm 实例使用该版本'
    }
    $chkInstances.Content = $instText
    $panel.Children.Add($chkInstances) | Out-Null

    $chkSources = [System.Windows.Controls.CheckBox]::new()
    $chkSources.IsEnabled = ($sourceInstances.Count -gt 0)
    $chkSources.IsChecked = $false
    $chkSources.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $srcText = [System.Windows.Controls.TextBlock]::new()
    $srcText.TextWrapping = 'Wrap'
    if ($sourceInstances.Count -gt 0) {
        $paths = ($sourceInstances | ForEach-Object { $_.source }) -join [Environment]::NewLine
        $srcText.Text = '同时删除 ' + $sourceInstances.Count + ' 个源码实例的源码目录和配置目录（' + (Format-Size $sourceSize) + '）：' + [Environment]::NewLine + $paths
    } else {
        $srcText.Text = '没有关联的源码目录'
    }
    $chkSources.Content = $srcText
    $panel.Children.Add($chkSources) | Out-Null

    $warn = [System.Windows.Controls.TextBlock]::new()
    $warn.Text = '删除后无法恢复。会话记录、凭证和已下载的依赖都会一并消失。'
    $warn.TextWrapping = 'Wrap'
    $warn.FontSize = 11
    $warn.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'DangerBrush')
    $warn.Margin = [System.Windows.Thickness]::new(0, 8, 0, 14)
    $panel.Children.Add($warn) | Out-Null

    $buttons = [System.Windows.Controls.StackPanel]::new()
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'

    $btnOk = [System.Windows.Controls.Button]::new()
    $btnOk.Content = '删除'
    $btnOk.Style = $script:Window.FindResource('PrimaryButton')
    $btnOk.Width = 90
    $btnOk.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $btnCancel = [System.Windows.Controls.Button]::new()
    $btnCancel.Content = '取消'
    $btnCancel.Width = 90
    $btnCancel.IsCancel = $true
    $btnCancel.Style = $script:Window.FindResource('SecondaryButton')
    $buttons.Children.Add($btnOk) | Out-Null
    $buttons.Children.Add($btnCancel) | Out-Null
    $panel.Children.Add($buttons) | Out-Null

    $dlg.Content = $panel
    $script:RemoveChoice = $null

    $btnOk.Add_Click({
        $script:RemoveChoice = [pscustomobject]@{
            DeleteInstances = [bool]$script:ChkInstances.IsChecked
            DeleteSources   = [bool]$script:ChkSources.IsChecked
        }
        $script:RemoveWindow.Close()
    })

    $script:RemoveWindow = $dlg
    $script:ChkInstances = $chkInstances
    $script:ChkSources = $chkSources

    $dlg.ShowDialog() | Out-Null
    return $script:RemoveChoice
}

function Remove-Version ([string]$version, [bool]$deleteInstances, [bool]$deleteSources) {
    $usage = Get-VersionUsage $version
    $removed = @()

    foreach ($inst in @($usage.Npm) + @($usage.Source)) {
        if ($script:Running[$inst.name]) { Stop-Instance $inst.name }
    }

    $versionDir = Join-Path $script:VersionsRoot $version
    if (Remove-Directory $versionDir) { $removed += ('versions\' + $version) }

    if ($deleteInstances) {
        foreach ($inst in $usage.Npm) {
            Remove-InstanceDir $inst
            $removed += ('实例 ' + $inst.name)
        }
    }

    if ($deleteSources) {
        foreach ($inst in $usage.Source) {
            if (Remove-Directory $inst.source) { $removed += ('source ' + $inst.source) }
            Remove-InstanceDir $inst
            $removed += ('实例 ' + $inst.name)
        }
    }

    Refresh-InstanceList
    Refresh-VersionList

    Append-Log ([Environment]::NewLine + '已删除版本 ' + $version + [Environment]::NewLine)
    foreach ($item in $removed) { Append-Log ('  - ' + $item + [Environment]::NewLine) }
}

function Invoke-RemoveVersion ([string]$version) {
    $usage = Get-VersionUsage $version
    $versionDir = Join-Path $script:VersionsRoot $version
    $versionSize = Get-DirSize $versionDir

    $homeSize = [long]0
    foreach ($inst in @($usage.Npm) + @($usage.Source)) { $homeSize += (Get-DirSize (Get-InstanceHome $inst)) }

    $sourceSize = [long]0
    foreach ($inst in $usage.Source) { $sourceSize += (Get-DirSize $inst.source) }

    $choice = Show-RemoveVersionDialog $version $versionSize $usage.Npm $usage.Source $homeSize $sourceSize
    if (-not $choice) { return }

    Remove-Version $version $choice.DeleteInstances $choice.DeleteSources
}

# ------------------------------------------------------------------ 对话框

function Show-AddDialog {
    $dlg = [System.Windows.Window]::new()
    $dlg.Title = '新增实例'
    $dlg.Width = 480
    $dlg.Height = 330
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Resources.MergedDictionaries.Add((New-ThemeDictionary $script:Theme))
    $dlg.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'WindowBrush')
    $dlg.SetResourceReference([System.Windows.Window]::ForegroundProperty, 'TextBrush')
    $dlg.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI')

    $grid = [System.Windows.Controls.Grid]::new()
    $grid.Margin = [System.Windows.Thickness]::new(18)
    foreach ($i in 0..6) {
        $rd = [System.Windows.Controls.RowDefinition]::new()
        $rd.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Auto)
        $grid.RowDefinitions.Add($rd)
    }
    $c0 = [System.Windows.Controls.ColumnDefinition]::new(); $c0.Width = [System.Windows.GridLength]::new(90)
    $c1 = [System.Windows.Controls.ColumnDefinition]::new()
    $grid.ColumnDefinitions.Add($c0); $grid.ColumnDefinitions.Add($c1)

    $versions = @(Get-InstalledVersions | ForEach-Object { $_.Version })
    $defaultName = 'instance-' + (Get-Instances).Count

    $labels = @('名称', 'dsh 版本', '端口', '工作目录')
    $boxes = @()
    for ($i = 0; $i -lt 4; $i++) {
        $tb = [System.Windows.Controls.TextBlock]::new()
        $tb.Text = $labels[$i]
        $tb.VerticalAlignment = 'Center'
        $tb.Margin = [System.Windows.Thickness]::new(0, 6, 8, 6)
        [System.Windows.Controls.Grid]::SetRow($tb, $i)
        [System.Windows.Controls.Grid]::SetColumn($tb, 0)
        $grid.Children.Add($tb) | Out-Null
    }

    $txtName = [System.Windows.Controls.TextBox]::new()
    $txtName.Text = $defaultName
    $txtName.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    [System.Windows.Controls.Grid]::SetRow($txtName, 0); [System.Windows.Controls.Grid]::SetColumn($txtName, 1)
    $grid.Children.Add($txtName) | Out-Null

    $cmbVer = [System.Windows.Controls.ComboBox]::new()
    $cmbVer.ItemsSource = $versions
    $cmbVer.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    if ($versions.Count -gt 0) { $cmbVer.SelectedIndex = 0 }
    [System.Windows.Controls.Grid]::SetRow($cmbVer, 1); [System.Windows.Controls.Grid]::SetColumn($cmbVer, 1)
    $grid.Children.Add($cmbVer) | Out-Null

    $txtPort = [System.Windows.Controls.TextBox]::new()
    $txtPort.Text = [string](Get-FreePort)
    $txtPort.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    [System.Windows.Controls.Grid]::SetRow($txtPort, 2); [System.Windows.Controls.Grid]::SetColumn($txtPort, 1)
    $grid.Children.Add($txtPort) | Out-Null

    $txtCwd = [System.Windows.Controls.TextBox]::new()
    $txtCwd.Text = (Get-Location).Path
    $txtCwd.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    [System.Windows.Controls.Grid]::SetRow($txtCwd, 3); [System.Windows.Controls.Grid]::SetColumn($txtCwd, 1)
    $grid.Children.Add($txtCwd) | Out-Null

    $modeLabel = [System.Windows.Controls.TextBlock]::new()
    $modeLabel.Text = '配置来源'
    $modeLabel.VerticalAlignment = 'Center'
    $modeLabel.Margin = [System.Windows.Thickness]::new(0, 6, 8, 6)
    [System.Windows.Controls.Grid]::SetRow($modeLabel, 4); [System.Windows.Controls.Grid]::SetColumn($modeLabel, 0)
    $grid.Children.Add($modeLabel) | Out-Null

    $cmbMode = [System.Windows.Controls.ComboBox]::new()
    $cmbMode.ItemsSource = @('独立配置', '共享配置', '桌面端配置')
    $cmbMode.SelectedIndex = 0
    $cmbMode.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    [System.Windows.Controls.Grid]::SetRow($cmbMode, 4); [System.Windows.Controls.Grid]::SetColumn($cmbMode, 1)
    $grid.Children.Add($cmbMode) | Out-Null

    $modeHint = [System.Windows.Controls.TextBlock]::new()
    $modeHint.Text = '独立：自己一份；共享：多个实例共用；桌面端：直接用 ~/.dsh，和桌面端共享工作区'
    $modeHint.TextWrapping = 'Wrap'
    $modeHint.FontSize = 11
    $modeHint.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'MutedBrush')
    $modeHint.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    [System.Windows.Controls.Grid]::SetRow($modeHint, 5); [System.Windows.Controls.Grid]::SetColumn($modeHint, 1)
    $grid.Children.Add($modeHint) | Out-Null

    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Orientation = 'Horizontal'
    $panel.HorizontalAlignment = 'Right'
    $panel.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($panel, 6)
    [System.Windows.Controls.Grid]::SetColumn($panel, 1)

    $btnOk = [System.Windows.Controls.Button]::new()
    $btnOk.Content = '确定'
    $btnOk.Style = $script:Window.FindResource('PrimaryButton')
    $btnOk.Width = 90
    $btnOk.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $btnOk.IsDefault = $true
    $btnCancel = [System.Windows.Controls.Button]::new()
    $btnCancel.Content = '取消'
    $btnCancel.Width = 90
    $btnCancel.IsCancel = $true
    $btnCancel.Style = $script:Window.FindResource('SecondaryButton')

    $panel.Children.Add($btnOk) | Out-Null
    $panel.Children.Add($btnCancel) | Out-Null
    $grid.Children.Add($panel) | Out-Null

    $dlg.Content = $grid
    $script:DlgResult = $null

    $btnOk.Add_Click({
        $name = $script:DlgName.Text.Trim()
        if (-not $name) { [System.Windows.MessageBox]::Show('名称不能为空。', '提示') | Out-Null; return }
        if (Get-Instances | Where-Object { $_.name -eq $name }) {
            [System.Windows.MessageBox]::Show('名称已存在。', '提示') | Out-Null; return
        }
        $port = 0
        if (-not [int]::TryParse($script:DlgPort.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            [System.Windows.MessageBox]::Show('端口无效。', '提示') | Out-Null; return
        }
        $script:DlgResult = [pscustomobject]@{
            Name      = $name
            Version   = [string]$script:DlgVer.SelectedItem
            Port      = $port
            Cwd      = $script:DlgCwd.Text.Trim()
            HomeMode = @('own', 'shared', 'desktop')[[Math]::Max(0, $script:DlgMode.SelectedIndex)]
        }
        $script:DlgWindow.Close()
    })

    $script:DlgWindow = $dlg
    $script:DlgName = $txtName
    $script:DlgVer = $cmbVer
    $script:DlgPort = $txtPort
    $script:DlgCwd = $txtCwd
    $script:DlgMode = $cmbMode

    $dlg.ShowDialog() | Out-Null
    return $script:DlgResult
}

# ------------------------------------------------------------------ 导入本机

function Import-Local {
    $candidates = @()

    $roots = @()
    foreach ($p in @($env:NVM_HOME, $env:NVM_ROOT)) { if ($p -and (Test-Path $p)) { $roots += $p } }
    foreach ($cmd in @(Get-Command node -All -CommandType Application -ErrorAction SilentlyContinue)) {
        $dir = Split-Path $cmd.Source -Parent
        if ((Split-Path $dir -Leaf) -in @('.nodejs', '.shim')) { $roots += (Split-Path $dir -Parent) }
    }
    foreach ($root in ($roots | Select-Object -Unique)) {
        $installs = Join-Path $root 'installs'
        if (Test-Path $installs) {
            foreach ($d in @(Get-ChildItem $installs -Directory -ErrorAction SilentlyContinue)) {
                $pkg = Join-Path $d.FullName 'node_modules\@deepseek-ai\dsh\package.json'
                if (Test-Path $pkg) { $candidates += $pkg }
            }
        }
    }
    foreach ($line in @(where.exe dsh 2>$null)) {
        $p = "$line".Trim()
        if (-not $p) { continue }
        $base = if ([System.IO.Path]::GetExtension($p)) { Split-Path $p -Parent } else { $p }
        $pkg = Join-Path $base 'node_modules\@deepseek-ai\dsh\package.json'
        if (Test-Path $pkg) { $candidates += $pkg }
    }

    $added = 0
    $seen = @{}
    foreach ($pkg in ($candidates | Select-Object -Unique)) {
        $info = Get-Content $pkg -Raw -Encoding utf8 | ConvertFrom-Json
        $bin = Join-Path (Split-Path $pkg -Parent) 'lib\bin.js'
        if (-not (Test-Path $bin)) { continue }
        if ($seen.ContainsKey($bin)) { continue }
        $seen[$bin] = $true

        $exists = Get-Instances | Where-Object { $_.bin -eq $bin }
        if ($exists) { continue }

        $name = ($info.version -replace '[^\w\.\-]', '_')
        if (Get-Instances | Where-Object { $_.name -eq $name }) { $name = $name + '-' + $added }

        Save-Instance ([pscustomobject]@{
            name       = $name
            dshVersion = $info.version
            bin        = $bin
            port       = (Get-FreePort)
            cwd        = (Get-Location).Path
            notes      = 'imported'
        }) | Out-Null
        $added++
    }

    if ($added -eq 0) {
        if (-not $script:Headless) { [System.Windows.MessageBox]::Show('没有发现新的本机 dsh 安装。', '导入') | Out-Null }
        return 0
    }
    if (-not $script:Headless) {
        Refresh-InstanceList
        Append-Log ('已导入 ' + $added + ' 个本机实例。' + [Environment]::NewLine)
    }
    return $added
}

if ($Import) {
    $script:Headless = $true
    $script:Cfg = Read-Config
    $n = Import-Local
    Write-Output ('imported=' + $n)
    Write-Output ('instances=' + (Get-Instances).Count)
    exit 0
}

# ------------------------------------------------------------------ 主循环

$window = [System.Windows.Markup.XamlReader]::Parse((Get-Content (Join-Path $script:Root 'ui.xaml') -Raw -Encoding utf8))

$iconFile = Join-Path $script:Root 'launcher.ico'
if (Test-Path $iconFile) {
    # 读进内存再解码，避免一直占着文件导致升级安装替换不掉
    try {
        $iconBytes = [System.IO.File]::ReadAllBytes($iconFile)
        $iconStream = [System.IO.MemoryStream]::new($iconBytes)
        # OnLoad：立刻解码完，之后关掉流也不会影响渲染（默认是延迟解码，关流后会抛 disposed object）
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
            $iconStream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $iconStream.Dispose()
    } catch { }
}

$script:LstInstances  = $window.FindName('lstInstances')
$script:LstVersions   = $window.FindName('lstVersions')
$script:CmbAvailable  = $window.FindName('cmbAvailable')
$script:TxtLog        = $window.FindName('txtLog')
$script:TxtLogPath    = $window.FindName('txtLogPath')
$script:TxtInstallState = $window.FindName('txtInstallState')
$script:LblLatest     = $window.FindName('lblLatest')
$script:BtnInstall    = $window.FindName('btnInstall')

Invoke-DataMigration

# 任务栏图标：WPF 只设 Window.Icon 时任务栏仍可能沿用宿主进程（pwsh）的图标，
# 这里在窗口句柄就绪后直接 WM_SETICON 把大小图标都换掉
$window.Add_SourceInitialized({
    try {
        $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        if ($handle -eq [IntPtr]::Zero) { return }

        # 窗口级 AUMID：任务栏据此分组，并取同名快捷方式的图标和名字
        [DshTaskbar]::SetWindowAppId($handle, 'ZhouJunquanaaa.DshLuncher') | Out-Null

        $big = [DshTaskbar]::LoadImage([IntPtr]::Zero, $iconFile, [DshTaskbar]::IMAGE_ICON, 32, 32, [DshTaskbar]::LR_LOADFROMFILE)
        $small = [DshTaskbar]::LoadImage([IntPtr]::Zero, $iconFile, [DshTaskbar]::IMAGE_ICON, 16, 16, [DshTaskbar]::LR_LOADFROMFILE)
        if ($big -ne [IntPtr]::Zero) { [DshTaskbar]::SendMessage($handle, [DshTaskbar]::WM_SETICON, [IntPtr]1, $big) | Out-Null }
        if ($small -ne [IntPtr]::Zero) { [DshTaskbar]::SendMessage($handle, [DshTaskbar]::WM_SETICON, [IntPtr]0, $small) | Out-Null }
    } catch { }
})

$script:Cfg = Read-Config
$script:Window = $window
$script:Theme = $(if ($script:Cfg.theme -in @('light', 'dark')) { $script:Cfg.theme } else { 'light' })
Set-Theme $script:Theme

$script:CmbRegistry = $window.FindName('cmbRegistry')
$script:TxtRegistryHint = $window.FindName('txtRegistryHint')
$script:CmbRegistry.ItemsSource = @($script:Registries | ForEach-Object { $_.Name })
$script:CmbRegistry.Text = Get-RegistryLabel (Get-RegistryUrl)
Update-RegistryHint

$script:BtnAppUpdate = $window.FindName('btnAppUpdate')
$script:LatestRelease = $null
Update-AppVersionLabel

function Update-Tick {
    Read-NewLog

    foreach ($name in @($script:Running.Keys)) {
        $r = $script:Running[$name]
        if ($r.Process.HasExited) {
            Append-Log ([Environment]::NewLine + '[' + $name + '] 进程已退出，退出码 ' + $r.Process.ExitCode + [Environment]::NewLine)
            $script:Running.Remove($name)
            continue
        }
        if (-not $r.Ready -and (Test-PortOpen $r.Port)) {
            $r.Ready = $true
            $r.OpenPending = $true
            $r.ReadyAt = Get-Date
            Append-Log ([Environment]::NewLine + '[' + $name + '] 端口已监听，等待 token ...' + [Environment]::NewLine)
        }

        if ($r.Ready -and $r.OpenPending) {
            $text = ''
            try { if (Test-Path $r.Log) { $text = Get-Content $r.Log -Raw -ErrorAction SilentlyContinue } } catch { }
            $match = [regex]::Match([string]$text, 'http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9_\-]+')
            $timedOut = ((Get-Date) - $r.ReadyAt).TotalSeconds -gt 15
            if ($match.Success -or $timedOut) {
                $url = if ($match.Success) { $match.Value } else { 'http://127.0.0.1:' + $r.Port + '/' }
                $r.Url = $url
                $r.OpenPending = $false
                Append-Log ([Environment]::NewLine + '[' + $name + '] 服务就绪：' + $url + [Environment]::NewLine)
                try { Start-Process $url } catch { }
            }
        }
    }

    if ($script:Install) {
        if ($script:Install.Process.HasExited) {
            $code = $script:Install.Process.ExitCode
            $ver = $script:Install.Version
            $script:Install = $null
            $script:BtnInstall.IsEnabled = $true
            if ($code -eq 0) {
                $script:TxtInstallState.Text = '已安装 ' + $ver
                Append-Log ([Environment]::NewLine + '安装完成：' + $ver + [Environment]::NewLine)
            } else {
                $script:TxtInstallState.Text = '安装失败（退出码 ' + $code + '），详见日志'
                Append-Log ([Environment]::NewLine + '安装失败，退出码 ' + $code + [Environment]::NewLine)
            }
            Refresh-VersionList
        }
    }

    $hash = @()
    foreach ($inst in (Get-Instances)) {
        $r = $script:Running[$inst.name]
        $s = 'stopped'
        if ($r) { $s = if ($r.Process.HasExited) { 'exited' } elseif ($r.Ready) { 'ready' } else { 'starting' } }
        $hash += $inst.name + ':' + $s
    }
    if (($hash -join '|') -ne $script:LastHash) { Refresh-InstanceList }
}

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({ try { Update-Tick } catch { } })
$timer.Start()

$window.FindName('btnStart').Add_Click({
    $inst = Get-SelectedInstance
    if (-not $inst) { [System.Windows.MessageBox]::Show('请先选中一个实例。', '提示') | Out-Null; return }
    try { Start-Instance $inst } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, '启动失败') | Out-Null }
})

$window.FindName('btnStop').Add_Click({
    $inst = Get-SelectedInstance
    if (-not $inst) { return }
    Stop-Instance $inst.name
})

$window.FindName('btnOpen').Add_Click({
    $inst = Get-SelectedInstance
    if (-not $inst) { return }
    $r = $script:Running[$inst.name]
    if (-not $r -or -not $r.Ready) {
        [System.Windows.MessageBox]::Show('该实例尚未运行。', '提示') | Out-Null; return
    }
    $target = if ($r.Url) { $r.Url } else { 'http://127.0.0.1:' + $r.Port + '/' }
    Start-Process $target
})

$window.FindName('btnAdd').Add_Click({
    $result = Show-AddDialog
    if (-not $result) { return }
    $created = Save-Instance ([pscustomobject]@{
        name       = $result.Name
        dshVersion = $result.Version
        bin        = (Get-BinPath $result.Version)
        port       = $result.Port
        cwd        = $result.Cwd
        notes      = ''
        homeMode   = $result.HomeMode
    })
    $homePath = Join-Path $created 'home'
    if (-not (Test-Path $homePath)) { New-Item -ItemType Directory -Path $homePath -Force | Out-Null; Seed-Home $homePath }
    Refresh-InstanceList
})

$window.FindName('btnRemove').Add_Click({
    $inst = Get-SelectedInstance
    if (-not $inst) { return }
    $answer = [System.Windows.MessageBox]::Show(
        '删除实例「' + $inst.name + '」？' + [Environment]::NewLine + [Environment]::NewLine +
        '会连同它的配置目录一起删除：' + [Environment]::NewLine + (Get-InstanceHome $inst),
        '确认', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    if ($script:Running[$inst.name]) { Stop-Instance $inst.name }
    Remove-InstanceDir $inst
    Refresh-InstanceList
})

$window.FindName('btnImport').Add_Click({ Import-Local })

$window.FindName('btnEditPort').Add_Click({
    try {
        $inst = Get-SelectedInstance
        if (-not $inst) {
            [System.Windows.MessageBox]::Show('请先选中一个实例。', '提示') | Out-Null
            return
        }
        Edit-InstancePort $inst
    } catch {
        Show-Error 'btnEditPort' $_
    }
})

$window.FindName('menuEditPort').Add_Click({
    try {
        $inst = Get-SelectedInstance
        if (-not $inst) { return }
        Edit-InstancePort $inst
    } catch {
        Show-Error 'menuEditPort' $_
    }
})

foreach ($pair in @(
    @{ Name = 'menuModeOwn'; Mode = 'own' },
    @{ Name = 'menuModeShared'; Mode = 'shared' },
    @{ Name = 'menuModeDesktop'; Mode = 'desktop' }
)) {
    $item = $window.FindName($pair.Name)
    $mode = $pair.Mode
    $item.Add_Click({
        try {
            $inst = Get-SelectedInstance
            if (-not $inst) { return }
            Set-InstanceHomeMode $inst $mode
        } catch {
            Show-Error 'menuMode' $_
        }
    }.GetNewClosure())
}

$window.FindName('menuOpenFolder').Add_Click({
    try {
        $inst = Get-SelectedInstance
        if (-not $inst) { return }
        $dir = if ($inst.dir) { $inst.dir } else { Get-InstanceDir $inst.name }
        if (Test-Path $dir) { Start-Process explorer.exe $dir }
    } catch {
        Show-Error 'menuOpenFolder' $_
    }
})

$window.FindName('cmbRegistry').Add_SelectionChanged({
    try {
        $picked = Resolve-RegistryInput $script:CmbRegistry.Text
        if ($picked) { Set-Registry $picked }
    } catch { }
})

$window.FindName('cmbRegistry').Add_LostFocus({
    try {
        $typed = Resolve-RegistryInput $script:CmbRegistry.Text
        if ($typed) { Set-Registry $typed } else { Update-RegistryHint }
    } catch { }
})

$window.FindName('btnTestRegistry').Add_Click({
    try {
        $url = Resolve-RegistryInput $script:CmbRegistry.Text
        if (-not $url) { $url = Get-RegistryUrl }
        $base = $url.TrimEnd('/')
        $script:TxtRegistryHint.Text = '测速中：' + $base
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-RestMethod ($base + '/@deepseek-ai%2Fdsh') -TimeoutSec 10
        $watch.Stop()
        $script:TxtRegistryHint.Text = (Get-RegistryLabel $url) + '：' + [int]$watch.ElapsedMilliseconds + ' ms'
    } catch {
        $script:TxtRegistryHint.Text = '测速失败：' + $_.Exception.Message
    }
})

$window.FindName('btnAppUpdate').Add_Click({
    try {
        if ($script:LatestRelease -and (Compare-AppVersion $script:LatestRelease.tag_name (Get-AppVersion)) -gt 0) {
            Start-AppUpdate
        } else {
            Check-AppUpdate
        }
    } catch {
        Show-Error 'btnAppUpdate' $_
    }
})

$window.FindName('btnTheme').Add_Click({
    try {
        $next = if ($script:Theme -eq 'light') { 'dark' } else { 'light' }
        Set-Theme $next
        $script:Cfg.theme = $next
        Save-Config
    } catch {
        Show-Error 'btnTheme' $_
    }
})

$window.FindName('btnAddSource').Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $picker = [System.Windows.Forms.FolderBrowserDialog]::new()
    $picker.Description = '选择 deepseek-harness 源码目录'
    $picker.ShowNewFolderButton = $false
    if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $dir = $picker.SelectedPath

    $entry = Join-Path $dir 'apps\cli\src\bin.ts'
    if (-not (Test-Path $entry)) {
        [System.Windows.MessageBox]::Show('该目录不是 deepseek-harness 仓库（缺少 apps\cli\src\bin.ts）。', '无效目录') | Out-Null
        return
    }

    $pkgPath = Join-Path $dir 'apps\cli\package.json'
    $ver = if (Test-Path $pkgPath) { (Get-Content $pkgPath -Raw -Encoding utf8 | ConvertFrom-Json).version } else { 'source' }

    $instanceName = 'src-' + (Split-Path $dir -Leaf)
    $base = $instanceName
    $n = 1
    while (Get-Instances | Where-Object { $_.name -eq $instanceName }) { $n++; $instanceName = $base + '-' + $n }

    $created = Save-Instance ([pscustomobject]@{
        name       = $instanceName
        dshVersion = $ver
        source     = $dir
        port       = (Get-FreePort)
        cwd        = $dir
        notes      = 'source'
    })
    $homePath = Join-Path $created 'home'
    if (-not (Test-Path $homePath)) { New-Item -ItemType Directory -Path $homePath -Force | Out-Null; Seed-Home $homePath }
    Refresh-InstanceList
    Append-Log ('已添加源码实例 ' + $instanceName + ' -> ' + $dir + [Environment]::NewLine)
})

$window.FindName('btnCheckUpdate').Add_Click({
    $script:LblLatest.Text = '最新版本：检查中...'
    try {
        $script:Registry = Get-RegistryInfo
        Refresh-VersionList
        Append-Log ('registry 最新版本：' + $script:Registry.Latest + '   next：' + $script:Registry.Next + '   alpha：' + $script:Registry.Alpha + [Environment]::NewLine)
    } catch {
        $script:LblLatest.Text = '最新版本：检查失败'
        Append-Log ('检查更新失败：' + $_.Exception.Message + [Environment]::NewLine)
    }
})

$script:BtnInstall.Add_Click({
    try {
        $sel = $script:CmbAvailable.SelectedItem
        if (-not $sel) {
            [System.Windows.MessageBox]::Show('请选择要安装的版本。', '提示') | Out-Null; return
        }
        $ver = ($sel -split '\s+')[0]
        Install-Version $ver
    } catch {
        Show-Error 'btnInstall' $_
    }
})

$window.FindName('btnRemoveVersion').Add_Click({
    try {
        $row = $script:LstVersions.SelectedItem
        if (-not $row) {
            [System.Windows.MessageBox]::Show('请先在「已安装版本」里选中一个版本。', '提示') | Out-Null
            return
        }
        Invoke-RemoveVersion $row.Version
    } catch {
        Show-Error 'btnRemoveVersion' $_
    }
})

$window.Add_Closing({
    param($s, $e)
    $active = @($script:Running.Keys)
    if ($active.Count -eq 0) { return }
    $answer = [System.Windows.MessageBox]::Show('还有 ' + $active.Count + ' 个实例在运行，退出时一并停止？', '确认', 'YesNoCancel')
    if ($answer -eq 'Cancel') { $e.Cancel = $true; return }
    if ($answer -eq 'Yes') { foreach ($n in $active) { Stop-Instance $n } }
})

$window.Add_ContentRendered({
    try {
        Check-AppUpdate -Silent
    } catch { }

    try {
        $script:Registry = Get-RegistryInfo
        Refresh-VersionList
        Append-Log ('已连接 registry，最新版本 ' + $script:Registry.Latest + [Environment]::NewLine)
    } catch {
        $script:LblLatest.Text = '最新版本：离线'
        Append-Log ('无法连接 registry：' + $_.Exception.Message + [Environment]::NewLine)
    }
})

Refresh-InstanceList
Refresh-VersionList

if ($SmokeTest) {
    Write-Output 'SMOKE OK'
    Write-Output ('instances=' + (Get-Instances).Count)
    Write-Output ('versions=' + ((Get-InstalledVersions).Count))
    exit 0
}

# 兜底：UI 线程上任何未捕获的异常都记录并提示，不再让进程直接退出
$window.Dispatcher.add_UnhandledException({
    param($sender, $eventArgs)
    Show-Error 'dispatcher' $eventArgs.Exception
    $eventArgs.Handled = $true
})

try {
    $window.ShowDialog() | Out-Null
} catch {
    Show-Error 'showdialog' $_
}
