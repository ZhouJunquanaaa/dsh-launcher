#Requires -Version 7.0
<#
    dsh 启动器（GUI）
    - 为每个实例维护独立的 DSH_HOME，互不污染配置/会话/凭证
    - 通过 npm --prefix 把指定版本的 dsh 装进 versions\ 目录，不影响全局 npm / nvm
    - 启动 dsh web 后轮询端口，就绪即打开浏览器
#>
[CmdletBinding()]
param([switch]$SmokeTest, [switch]$Import)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Root         = $PSScriptRoot
# 安装版（存在 installed.flag）把用户数据放到 %LOCALAPPDATA%；便携版放脚本旁边
$script:DataRoot     = if (Test-Path (Join-Path $script:Root 'installed.flag')) { Join-Path $env:LOCALAPPDATA 'dsh-launcher' } else { $script:Root }
$script:ConfigPath   = Join-Path $script:DataRoot 'launcher.json'
$script:VersionsRoot = Join-Path $script:DataRoot 'versions'
$script:HomesRoot    = Join-Path $script:DataRoot 'homes'
$script:LogsRoot     = Join-Path $script:DataRoot 'logs'
$script:SeedFiles    = @('settings.yaml', '.credentials.yaml', '.env')
$script:Running      = @{}
$script:Install      = $null
$script:Tail         = @()
$script:Registry     = $null
$script:LastHash     = ''
$script:Headless     = $false

foreach ($d in @($script:VersionsRoot, $script:HomesRoot, $script:LogsRoot)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ------------------------------------------------------------------ 配置

function New-DefaultConfig {
    [ordered]@{ version = 1; instances = @() }
}

function Read-Config {
    if (-not (Test-Path $script:ConfigPath)) { return (New-DefaultConfig) }
    $raw = Get-Content $script:ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    $cfg = New-DefaultConfig
    if ($raw.PSObject.Properties['instances'] -and $raw.instances) { $cfg.instances = @($raw.instances) }
    return $cfg
}

function Save-Config {
    $script:Cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ConfigPath -Encoding utf8
}

function Get-Instances {
    if (-not $script:Cfg.instances) { return @() }
    return @($script:Cfg.instances)
}

# ------------------------------------------------------------------ 工具

function Get-NodePath {
    $cmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { throw 'PATH 中找不到 node.exe' }
    return $cmd.Source
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
        if (Test-Path $pkg) {
            $v = (Get-Content $pkg -Raw -Encoding utf8 | ConvertFrom-Json).version
            $rows += [pscustomobject]@{ Version = $v; Source = 'versions\' }
        }
    }
    return @($rows | Sort-Object Version -Descending)
}

function Get-RegistryInfo {
    $m = Invoke-RestMethod 'https://registry.npmjs.org/@deepseek-ai/dsh' -TimeoutSec 25
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
            [System.Windows.MessageBox]::Show("版本 $($inst.dshVersion) 的 dsh 未安装到本地 versions 目录。" + [Environment]::NewLine + '请先在右侧【安装新版本】。', '缺少版本') | Out-Null
            return
        }
    }

    $homePath = $inst.dshHome
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
        $rows += [pscustomobject]@{
            Name    = $inst.name
            Version = $label
            Port    = $inst.port
            Status  = $status
            Home    = $inst.dshHome
        }
    }
    $script:LstInstances.ItemsSource = $rows
    if ($selected) {
        foreach ($row in $rows) {
            if ($row.Name -eq $selected) { $script:LstInstances.SelectedItem = $row; break }
        }
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

    $proc = Start-Process -FilePath 'npm.cmd' -ArgumentList @('i', '-g', '@deepseek-ai/dsh@' + $version, '--prefix', $target, '--no-audit', '--no-fund') -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden -PassThru

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

# ------------------------------------------------------------------ 对话框

function Show-AddDialog {
    $dlg = [System.Windows.Window]::new()
    $dlg.Title = '新增实例'
    $dlg.Width = 480
    $dlg.Height = 330
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#1B1B1F')
    $dlg.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E6E6E6')
    $dlg.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI')

    $grid = [System.Windows.Controls.Grid]::new()
    $grid.Margin = [System.Windows.Thickness]::new(18)
    foreach ($i in 0..4) {
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

    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Orientation = 'Horizontal'
    $panel.HorizontalAlignment = 'Right'
    $panel.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($panel, 4)
    [System.Windows.Controls.Grid]::SetColumn($panel, 1)

    $btnOk = [System.Windows.Controls.Button]::new()
    $btnOk.Content = '确定'
    $btnOk.Width = 90
    $btnOk.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $btnOk.IsDefault = $true
    $btnCancel = [System.Windows.Controls.Button]::new()
    $btnCancel.Content = '取消'
    $btnCancel.Width = 90
    $btnCancel.IsCancel = $true

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
            Name    = $name
            Version = [string]$script:DlgVer.SelectedItem
            Port    = $port
            Cwd     = $script:DlgCwd.Text.Trim()
        }
        $script:DlgWindow.Close()
    })

    $script:DlgWindow = $dlg
    $script:DlgName = $txtName
    $script:DlgVer = $cmbVer
    $script:DlgPort = $txtPort
    $script:DlgCwd = $txtCwd

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

        $homePath = Join-Path $script:HomesRoot $name
        $script:Cfg.instances = @(Get-Instances) + [ordered]@{
            name        = $name
            dshVersion  = $info.version
            bin         = $bin
            dshHome     = $homePath
            port        = (Get-FreePort)
            cwd         = (Get-Location).Path
            notes       = 'imported'
        }
        $added++
    }

    if ($added -eq 0) {
        if (-not $script:Headless) { [System.Windows.MessageBox]::Show('没有发现新的本机 dsh 安装。', '导入') | Out-Null }
        return 0
    }
    Save-Config
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

$script:LstInstances  = $window.FindName('lstInstances')
$script:LstVersions   = $window.FindName('lstVersions')
$script:CmbAvailable  = $window.FindName('cmbAvailable')
$script:TxtLog        = $window.FindName('txtLog')
$script:TxtLogPath    = $window.FindName('txtLogPath')
$script:TxtInstallState = $window.FindName('txtInstallState')
$script:LblLatest     = $window.FindName('lblLatest')
$script:BtnInstall    = $window.FindName('btnInstall')

$script:Cfg = Read-Config

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
    $homePath = Join-Path $script:HomesRoot $result.Name
    $script:Cfg.instances = @(Get-Instances) + [ordered]@{
        name       = $result.Name
        dshVersion = $result.Version
        bin        = (Get-BinPath $result.Version)
        dshHome    = $homePath
        port       = $result.Port
        cwd        = $result.Cwd
        notes      = ''
    }
    Save-Config
    if (-not (Test-Path $homePath)) { New-Item -ItemType Directory -Path $homePath -Force | Out-Null; Seed-Home $homePath }
    Refresh-InstanceList
})

$window.FindName('btnRemove').Add_Click({
    $inst = Get-SelectedInstance
    if (-not $inst) { return }
    $answer = [System.Windows.MessageBox]::Show('删除实例「' + $inst.name + '」？' + [Environment]::NewLine + '仅删除配置，不删除 home 目录。', '确认', 'YesNo')
    if ($answer -ne 'Yes') { return }
    if ($script:Running[$inst.name]) { Stop-Instance $inst.name }
    $script:Cfg.instances = @(Get-Instances | Where-Object { $_.name -ne $inst.name })
    Save-Config
    Refresh-InstanceList
})

$window.FindName('btnImport').Add_Click({ Import-Local })

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

    $homePath = Join-Path $script:HomesRoot $instanceName
    $script:Cfg.instances = @(Get-Instances) + [ordered]@{
        name       = $instanceName
        dshVersion = $ver
        source     = $dir
        dshHome    = $homePath
        port       = (Get-FreePort)
        cwd        = $dir
        notes      = 'source'
    }
    Save-Config
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
    $sel = $script:CmbAvailable.SelectedItem
    if (-not $sel) {
        [System.Windows.MessageBox]::Show('请选择要安装的版本。', '提示') | Out-Null; return
    }
    $ver = ($sel -split '\s+')[0]
    Install-Version $ver
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

$window.ShowDialog() | Out-Null
