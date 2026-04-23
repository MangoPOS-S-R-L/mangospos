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
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
CloseApplications=force
RestartApplications=no
AppMutex=MangoPOS_App_Mutex
#ifdef SignApp
SignTool=standard $f
#endif

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "rundiagnostics"; Description: "Ejecutar diagnostico de conectividad al finalizar"; Flags: unchecked

[Files]
Source: "..\..\build\installer_stage\App\*"; DestDir: "{app}\App"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\build\installer_stage\Agent\*"; DestDir: "{app}\Agent"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: ShouldInstallAgent
Source: "..\..\build\installer_stage\Support\*"; DestDir: "{app}\Support"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\App\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\App\{#AppExeName}"; Tasks: desktopicon
Name: "{autoprograms}\{#AppName}\Diagnosticar conectividad"; Filename: "{app}\Support\Diagnose-MangoPOS.cmd"; IconFilename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"
Name: "{autoprograms}\{#AppName}\Reparar red y TLS"; Filename: "{app}\Support\Repair-MangoPOS-Network.cmd"; IconFilename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"

[Run]
Filename: "{cmd}"; Parameters: "/c sc config W32Time start= auto >nul 2>&1 && net start W32Time >nul 2>&1 && w32tm /resync /force >nul 2>&1"; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/c taskkill /F /IM mangopos-agent.exe /T >nul 2>&1"; Flags: runhidden waituntilterminated; Check: ShouldInstallAgent
Filename: "{cmd}"; Parameters: "/c taskkill /F /IM mangopos-agent-service.exe /T >nul 2>&1"; Flags: runhidden waituntilterminated; Check: ShouldInstallAgent
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "stop"; Flags: runhidden waituntilterminated; Check: ShouldStopExistingAgentService
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "uninstall"; Flags: runhidden waituntilterminated; Check: ShouldStopExistingAgentService
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "install"; Flags: runhidden waituntilterminated; Check: ShouldInstallAgent
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "start"; Flags: runhidden waituntilterminated postinstall skipifsilent; Description: "Iniciar agente LAN de impresion"; Check: ShouldInstallAgent
Filename: "{app}\Support\Diagnose-MangoPOS.cmd"; Flags: shellexec postinstall skipifsilent; Tasks: rundiagnostics; Description: "Ejecutar diagnostico de conectividad"

[UninstallRun]
Filename: "{cmd}"; Parameters: "/c taskkill /F /IM mangopos-agent.exe /T >nul 2>&1"; Flags: runhidden waituntilterminated; RunOnceId: "KillMangoPOSAgentProcess"
Filename: "{cmd}"; Parameters: "/c taskkill /F /IM mangopos-agent-service.exe /T >nul 2>&1"; Flags: runhidden waituntilterminated; RunOnceId: "KillMangoPOSAgentWrapper"
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "stop"; Flags: runhidden waituntilterminated; RunOnceId: "StopMangoPOSAgentService"
Filename: "{app}\Agent\{#AgentServiceWrapper}"; Parameters: "uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "UninstallMangoPOSAgentService"

[Code]
var
  AgentInstallSkipped: Boolean;

function IsSupportedWindows: Boolean;
var
  Version: TWindowsVersion;
begin
  GetWindowsVersionEx(Version);
  // Windows 7 = 6.1, Windows 8 = 6.2, Windows 8.1 = 6.3, Windows 10+ = 10.0
  Result := (Version.Major > 6) or ((Version.Major = 6) and (Version.Minor >= 1));
end;

function InitializeSetup: Boolean;
begin
  if not IsSupportedWindows then
  begin
    MsgBox(
      'MangoPOS requiere Windows 7 o superior en 64 bits.' + #13#10 +
      'Esta maquina no cumple el requisito minimo del sistema.',
      mbCriticalError,
      MB_OK
    );
    Result := False;
    exit;
  end;

  Result := True;
end;

function CommandSucceeds(FileName: String; Params: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(FileName, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

function AgentServiceRunning: Boolean;
begin
  Result := CommandSucceeds(
    ExpandConstant('{cmd}'),
    '/c sc query "{#AgentServiceName}" | find /I "RUNNING" >nul 2>&1'
  );
end;

function AgentHealthEndpointRunning: Boolean;
begin
  Result := CommandSucceeds(
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -Command "' +
    'try { ' +
    '$r = Invoke-WebRequest -UseBasicParsing -Uri ''http://127.0.0.1:4000/health'' -TimeoutSec 2; ' +
    '$json = $r.Content | ConvertFrom-Json; ' +
    'if ($r.StatusCode -eq 200 -and $json.status -eq ''ok'' -and $json.PSObject.Properties.Name -contains ''agent'') { exit 0 } ' +
    '} catch { }; exit 1"'
  );
end;

function AgentServiceRegistered: Boolean;
begin
  Result := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\{#AgentServiceName}');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  AgentInstallSkipped := AgentServiceRunning or AgentHealthEndpointRunning;

  if AgentInstallSkipped then
  begin
    Log('MangoPOS Agent already running. Installer will skip agent file copy/service reinstall.');
  end
  else
  begin
    Log('MangoPOS Agent not detected as running. Installer will install/start bundled agent.');
  end;

  Result := '';
end;

function ShouldInstallAgent: Boolean;
begin
  Result := not AgentInstallSkipped;
end;

function ShouldStopExistingAgentService: Boolean;
begin
  Result := ShouldInstallAgent and AgentServiceRegistered;
end;
