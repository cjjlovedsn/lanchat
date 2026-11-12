; LanChat Windows installer
; build:  ISCC.exe lanchat.iss   (from the installer/ directory)

#define MyAppName "LanChat"
#ifndef MyAppVersion
  #define MyAppVersion "1.0.5"
#endif
#define MyAppExeName "lanchat.exe"

[Setup]
AppId={{8B6A2F1E-9C4D-4E7A-B3F2-1A5C6D8E9F01}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=lanchat-setup
SetupIconFile=..\assets\tray_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式(&D)"; GroupDescription: "附加任务:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "运行 LanChat"; Flags: nowait postinstall skipifsilent

[Code]
var
  ResultCode: Integer;

procedure AddFwRule(Proto: String);
var
  Params: String;
begin
  Params := Format('advfirewall firewall add rule name="LanChat" dir=in action=allow enable=yes profile=any protocol=%s program="%s\lanchat.exe"', [Proto, ExpandConstant('{app}')]);
  Exec(ExpandConstant('{sys}\netsh.exe'), Params, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
end;

procedure DeleteFwRules();
begin
  Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall delete rule name="LanChat" program="' + ExpandConstant('{app}') + '\lanchat.exe"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  // inbound allow rules so discovery (UDP) and transfers (TCP) always work,
  // regardless of what the user clicks on the Windows security prompt
  if CurStep = ssPostInstall then
  begin
    DeleteFwRules;
    AddFwRule('TCP');
    AddFwRule('UDP');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    DeleteFwRules;
end;
