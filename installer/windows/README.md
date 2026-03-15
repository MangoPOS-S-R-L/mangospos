# MangoPOS Windows MSI

Ruta preparada para generar un instalador MSI de MangoPOS que además instala el agente LAN.

## Requisitos en Windows

- Flutter SDK en PATH
- WiX Toolset v3 (`candle`, `light`) en PATH
- Windows SDK con `signtool.exe`
- Certificado de firma (`.pfx`) si se va a firmar
- Node.js instalado en la máquina destino o agente bundleado con runtime propio

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

## Qué hace

- compila `flutter build windows --release`
- prepara stage con app + carpeta `agent`
- compila MSI con WiX
- instala MangoPOS en `Program Files\MangoPOS`
- deja el agente LAN dentro de `Program Files\MangoPOS\Agent`
- ejecuta `setup.bat` del agente durante instalación
- opcionalmente firma el MSI con `signtool`

## Importante

El estado actual deja la ruta de build lista, pero la firma real solo puede ejecutarse en Windows con certificado válido.
