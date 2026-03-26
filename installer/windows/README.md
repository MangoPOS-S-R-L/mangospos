# MangoPOS Windows Installer

Ruta preparada para generar instaladores de Windows para MangoPOS, incluyendo el agente LAN.

## Requisitos en Windows

- Flutter SDK en PATH
- Inno Setup 6 (`ISCC.exe`) instalado
- WiX Toolset (`wix`) en PATH, solo si tambien vas a generar MSI
- Windows SDK con `signtool.exe`
- Certificado de firma (`.pfx`) si se va a firmar
- Node.js y npm en la maquina de build

## Generar EXE con Inno Setup

```powershell
cd installer/windows
powershell -ExecutionPolicy Bypass -File .\build_inno.ps1
```

Si ya tienes `build\windows\x64\runner\Release`, `agent\dist\mangopos-agent.exe` y `build\installer_stage` listos:

```powershell
cd installer/windows
powershell -ExecutionPolicy Bypass -File .\build_inno.ps1 -SkipFlutterBuild -SkipAgentBuild -SkipStage
```

## Generar MSI

```powershell
cd installer/windows
powershell -ExecutionPolicy Bypass -File .\build_msi.ps1 -SkipSign
```

## Generar y firmar MSI

```powershell
cd installer/windows
powershell -ExecutionPolicy Bypass -File .\build_msi.ps1 -CertPfx "C:\certs\mangopos.pfx" -CertPassword "TU_PASSWORD"
```

## Firmar un MSI ya generado

```powershell
powershell -ExecutionPolicy Bypass -File .\sign_msi.ps1 -MsiPath "C:\ruta\MangoPOS-Setup-1.0.0-x64.msi" -CertPfx "C:\certs\mangopos.pfx" -CertPassword "TU_PASSWORD"
```

## Que hace

- compila `flutter build windows --release`
- compila `agent\dist\mangopos-agent.exe`
- prepara stage con app + carpeta `Agent`
- compila un `.exe` con Inno Setup en `build\installer`
- compila MSI con WiX
- instala MangoPOS en `Program Files\MangoPOS`
- deja el agente LAN dentro de `Program Files\MangoPOS\Agent`
- registra el agente LAN como servicio con WinSW
- opcionalmente firma el MSI con `signtool`

## Importante

La firma real solo puede ejecutarse en Windows con certificado valido.
