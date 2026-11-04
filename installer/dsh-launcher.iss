; dsh 启动器 安装脚本（Inno Setup 6）
; 编译：ISCC.exe installer\dsh-launcher.iss

#define AppVersion "1.0.0"
#define AppNameCn "dsh 启动器"
#define AppPublisher "ZhouJunquanaaa"
#define AppUrl "https://github.com/ZhouJunquanaaa/dsh-launcher"

[Setup]
AppId={{8F3C1A52-9E4B-4D7A-B2C1-7A5E9D3F6B84}
AppName={#AppNameCn}
AppVersion={#AppVersion}
AppVerName={#AppNameCn} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\dsh-launcher
DefaultGroupName={#AppNameCn}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=dsh-launcher-setup-{#AppVersion}
SetupIconFile=..\launcher.ico
UninstallDisplayIcon={app}\launcher.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "..\dsh-launcher.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dsh-launcher.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\ui.xaml"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\launcher.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "installed.flag"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppNameCn}"; Filename: "{app}\dsh-launcher.cmd"; IconFilename: "{app}\launcher.ico"; WorkingDir: "{app}"
Name: "{group}\Uninstall {#AppNameCn}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppNameCn}"; Filename: "{app}\dsh-launcher.cmd"; IconFilename: "{app}\launcher.ico"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\dsh-launcher.cmd"; Description: "Launch {#AppNameCn}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
function PwshPresent(): Boolean;
begin
  Result :=
    FileExists(ExpandConstant('{localappdata}\Microsoft\WindowsApps\pwsh.exe')) or
    FileExists(ExpandConstant('{pf}\PowerShell\7\pwsh.exe')) or
    FileExists(ExpandConstant('{pf32}\PowerShell\7\pwsh.exe'));
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if not PwshPresent() then
  begin
    if MsgBox('PowerShell 7 (pwsh) was not found.' + #13#10 + #13#10 +
              'The launcher needs PowerShell 7 to run its GUI. Install it first:' + #13#10 +
              '    winget install Microsoft.PowerShell' + #13#10 + #13#10 +
              'Continue the installation anyway?',
              mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end;
end;
