; dsh-luncher 安装脚本（Inno Setup 6）
; 编译：ISCC.exe installer\dsh-luncher.iss

#define AppVersion "2.1.0"
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
DefaultDirName={code:GetDefaultDir}
DisableDirPage=no
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
Source: "..\version.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\dsh-luncher.exe"; IconFilename: "{app}\launcher.ico"; WorkingDir: "{app}"; AppUserModelID: "ZhouJunquanaaa.DshLuncher"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\dsh-luncher.exe"; IconFilename: "{app}\launcher.ico"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "ZhouJunquanaaa.DshLuncher"

[Run]
Filename: "{app}\dsh-luncher.exe"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKCU; Subkey: "Software\dsh-luncher"; ValueType: string; ValueName: "DataDir"; ValueData: "{code:GetDataDir}"; Flags: createvalueifdoesntexist

[Code]
var
  DataDirPage: TInputDirWizardPage;
  LastAutoDataDir: String;
  DataDirOverride: String;

function ResolveDataDir(): String;
begin
  if DataDirOverride <> '' then
    Result := DataDirOverride
  else
    Result := DataDirPage.Values[0];
end;

function GetDefaultDir(Param: String): String;
begin
  { 默认装到 D 盘，避免占 C 盘；没有 D 盘就退回用户目录 }
  if DirExists('D:\') then
    Result := 'D:\dsh-luncher'
  else
    Result := ExpandConstant('{autopf}\dsh-luncher');
end;

procedure InitializeWizard;
begin
  DataDirPage := CreateInputDirPage(wpSelectDir,
    '选择数据目录',
    '已下载的 dsh 版本、实例配置和日志放在哪里？',
    '默认放在安装目录下的 data 文件夹。想省 C 盘空间就换到别的盘。',
    False, '');
  DataDirPage.Add('数据目录：');
  DataDirPage.Values[0] := '';
  LastAutoDataDir := '';

  { 命令行 /DATADIR=... 覆盖，便于静默安装 }
  if DataDirOverride <> '' then
  begin
    DataDirPage.Values[0] := DataDirOverride;
    LastAutoDataDir := DataDirOverride;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ProposedDataDir: String;
begin
  Result := True;
  // 用户没改过数据目录时，跟着安装目录一起变（app 常量在这里才可用）
  if (CurPageID = wpSelectDir) and (DataDirOverride = '') then
  begin
    ProposedDataDir := AddBackslash(WizardForm.DirEdit.Text) + 'data';
    if (DataDirPage.Values[0] = '') or (CompareText(DataDirPage.Values[0], LastAutoDataDir) = 0) then
    begin
      DataDirPage.Values[0] := ProposedDataDir;
      LastAutoDataDir := ProposedDataDir;
    end;
  end;
end;

function GetDataDir(Param: String): String;
begin
  Result := ResolveDataDir();
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  DataDir: String;
begin
  if CurStep = ssPostInstall then
  begin
    DataDir := ResolveDataDir();
    if DataDir <> '' then
    begin
      ForceDirectories(DataDir);
      SaveStringToFile(ExpandConstant('{app}\data-dir.txt'), DataDir, False);
    end;
  end;
end;

function ReadDataDir(): String;
begin
  Result := '';
  if not RegQueryStringValue(HKCU, 'Software\dsh-luncher', 'DataDir', Result) then
    Result := '';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ReadDataDir();
    if (DataDir <> '') and DirExists(DataDir) then
    begin
      if MsgBox('是否同时删除数据目录？' + #13#10 + DataDir + #13#10 + #13#10 +
                '里面是已下载的 dsh 版本、实例配置和日志。' + #13#10 +
                '选「否」会保留，方便以后重装继续用。',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(DataDir, True, True, True);
    end;
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\dsh-luncher');
  end;
end;

function PwshPresent(): Boolean;
begin
  Result :=
    FileExists(ExpandConstant('{localappdata}\Microsoft\WindowsApps\pwsh.exe')) or
    FileExists(ExpandConstant('{pf}\PowerShell\7\pwsh.exe')) or
    FileExists(ExpandConstant('{pf32}\PowerShell\7\pwsh.exe'));
end;

function InitializeSetup(): Boolean;
begin
  DataDirOverride := ExpandConstant('{param:DATADIR|}');
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
