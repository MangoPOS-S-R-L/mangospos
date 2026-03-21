#define AppName "MangoPOS"
#define AppVersion "1.0.0"
#define AppPublisher "Cristian Gomez"
#define AppURL "https://mangopos.com"
#define AppExeName "mangopos.exe"

[Setup]
AppId={{8D0F13E8-6A4B-4B62-9700-A4B2EBAA7C51}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
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
; App files (from stage)
Source: "..\..\build\installer_stage\App\*"; DestDir: "{app}\App"; Flags: ignoreversion recursesubdirs createallsubdirs
; Agent files (from stage)
Source: "..\..\build\installer_stage\Agent\*"; DestDir: "{app}\Agent"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\App\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\App\{#AppExeName}"; Tasks: desktopicon

[Run]
; Instalar el Servicio mediante WinSW
Filename: "{app}\Agent\mangopos-agent-service.exe"; Parameters: "install"; Flags: runascurrentuser runhidden
; Iniciar el Servicio
Filename: "{app}\Agent\mangopos-agent-service.exe"; Parameters: "start"; Flags: runascurrentuser runhidden postinstall; Description: "Iniciar Agente LAN de Impresión"

[UninstallRun]
; Detener y Remover el Servicio
Filename: "{app}\Agent\mangopos-agent-service.exe"; Parameters: "stop"; Flags: runhidden
Filename: "{app}\Agent\mangopos-agent-service.exe"; Parameters: "uninstall"; Flags: runhidden
