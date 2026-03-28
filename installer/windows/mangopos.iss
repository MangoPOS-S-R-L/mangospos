#ifndef AppName
  #define AppName "MangoPOS"
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef AppPublisher
  #define AppPublisher "Cristian Gomez"
#endif
#ifndef AppURL
  #define AppURL "https://mangopos.com"
#endif
#ifndef AppExeName
  #define AppExeName "mangopos.exe"
#endif

#define AgentServiceName "MangoPOSAgent"
#define AgentServiceWrapper "mangopos-agent-service.exe"

[Setup]
AppId={{8D0F13E8-6A4B-4B62-9700-A4B2EBAA7C51}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\installer
OutputBaseFilename=MangoPOS-Setup-{#AppVersion}-x64
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\installer_stage\App\*"; DestDir: "{app}\App"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\build\installer_stage\Agent\*"; DestDir: "{app}\Agent"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\App\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\App\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{cmd}"; Parameters: "/c taskkill /F /IM mangopos-agent.exe /T >nul 2>&1"; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/c taskkill /F /IM mangopos-agent-service.exe /T >nul 2>&1"; Flags: runhidden waituntilterminated
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "stop"; Flags: runhidden waituntilterminated; Check: AgentServiceRegistered
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "uninstall"; Flags: runhidden waituntilterminated; Check: AgentServiceRegistered
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "install"; Flags: runhidden waituntilterminated
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "start"; Flags: runhidden waituntilterminated postinstall skipifsilent; Description: "Iniciar agente LAN de impresion"

[UninstallRun]
Filename: "{cmd}"; Parameters: "/c taskkill /F /IM mangopos-agent.exe /T >nul 2>&1"; Flags: runhidden waituntilterminated; RunOnceId: "KillMangoPOSAgentProcess"
Filename: "{cmd}"; Parameters: "/c taskkill /F /IM mangopos-agent-service.exe /T >nul 2>&1"; Flags: runhidden waituntilterminated; RunOnceId: "KillMangoPOSAgentWrapper"
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "stop"; Flags: runhidden waituntilterminated; RunOnceId: "StopMangoPOSAgentService"
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "UninstallMangoPOSAgentService"

[Code]
function AgentServiceRegistered: Boolean;
begin
  Result := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\{#AgentServiceName}');
end;
