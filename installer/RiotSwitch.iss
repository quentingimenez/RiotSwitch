; Installateur RiotSwitch (Inno Setup 6)
; Compilation : "C:\Users\<user>\AppData\Local\Programs\Inno Setup 6\ISCC.exe" installer\RiotSwitch.iss
; Version : passée par le workflow de release avec /DMyAppVersion=1.1.17

#ifndef MyAppVersion
  #define MyAppVersion "1.1.17"
#endif

#define MyAppName "RiotSwitch"
#define MyAppPublisher "quentingimenez"
#define MyAppURL "https://github.com/quentingimenez/RiotSwitch"
#define MyAppExeName "RiotSwitch.exe"

[Setup]
AppId={{A8CD0F92-3E65-4CAF-B96A-FA55A369E97B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\Programs\RiotSwitch
DefaultGroupName=RiotSwitch
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist-installer
OutputBaseFilename=RiotSwitch-Setup-x64-{#MyAppVersion}
SetupIconFile=..\src\RiotSwitcher.App\Assets\app.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#MyAppVersion}.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} {#MyAppVersion}
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoCopyright=quentingimenez

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "Créer un raccourci sur le Bureau"; GroupDescription: "Raccourcis :"; Flags: unchecked
Name: "startup"; Description: "Démarrer le veilleur RiotSwitch avec Windows"; GroupDescription: "Démarrage :"; Flags: unchecked

[Files]
Source: "..\dist\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\RiotSwitch"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"; Comment: "Gestionnaire de comptes Riot"
Name: "{group}\RiotSwitch — Paramètres"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--settings"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{group}\Riot Client (Switch)"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--launch-riot --ephemeral"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{group}\Désinstaller RiotSwitch"; Filename: "{uninstallexe}"
Name: "{autodesktop}\RiotSwitch"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\RiotSwitch.lnk"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--watch"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: startup

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Lancer RiotSwitch"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM RiotSwitch.exe /F"; Flags: runhidden; RunOnceId: "StopRiotSwitch"

[Code]
function HasDotNet8Desktop(): Boolean;
var
  FindRec: TFindRec;
begin
  Result := FindFirst(ExpandConstant('{commonpf64}\dotnet\shared\Microsoft.WindowsDesktop.App\8.*'), FindRec);
  if Result then
    FindClose(FindRec);
end;

function InitializeSetup(): Boolean;
var
  ErrorCode: Integer;
begin
  if HasDotNet8Desktop() then
  begin
    Result := True;
    Exit;
  end;

  if MsgBox('RiotSwitch nécessite Microsoft .NET 8 Desktop Runtime (x64).' + #13#10 + #13#10 +
            'OK ouvre la page de téléchargement ; Annuler arrête l''installation.',
            mbError, MB_OKCANCEL) = IDOK then
  begin
    ShellExec('open', 'https://dotnet.microsoft.com/download/dotnet/8.0', '', '',
      SW_SHOWNORMAL, ewNoWait, ErrorCode);
  end;

  Result := False;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM RiotSwitch.exe /F', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;
