; dsh-luncher 安装脚本（Inno Setup 6）
; 编译：ISCC.exe installer\dsh-luncher.iss

#define AppVersion "1.3.0"
#define AppName "dsh-luncher"
#define AppPublisher "ZhouJunquanaaa"
#define AppUrl "https://github.com/ZhouJunquanaaa/dsh-launcher"

[Setup]
AppId={{B7E4D2A1-3C5F-4A8B-9D2E-6F1C8A4B7D93}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\dsh-luncher
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=dsh-luncher-setup-{#AppVersion}
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
Source: "..\dsh-luncher.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dsh-luncher.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dsh-luncher.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\ui.xaml"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\themes\*.xaml"; DestDir: "{app}\themes"; Flags: ignoreversion
Source: "..\launcher.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "installed.flag"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\dsh-luncher.exe"; IconFilename: "{app}\launcher.ico"; WorkingDir: "{app}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\dsh-luncher.exe"; IconFilename: "{app}\launcher.ico"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\dsh-luncher.exe"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

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
              'dsh-luncher needs PowerShell 7 to run its GUI. Install it first:' + #13#10 +
              '    winget install Microsoft.PowerShell' + #13#10 + #13#10 +
              'Continue the installation anyway?',
              mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end;
end;
