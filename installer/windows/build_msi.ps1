param(
  [string]$Configuration = "Release",
  [string]$Platform = "x64",
  [string]$CertPfx = "",
  [string]$CertPassword = "",
  [switch]$SkipSign
)

$ErrorActionPreference = "Stop"

function Require-Tool([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Falta herramienta requerida: $Name"
  }
}

function Find-SignTool {
  $paths = @(
    "$Env:ProgramFiles (x86)\Windows Kits\10\bin\x64\signtool.exe",
    "$Env:ProgramFiles\Windows Kits\10\bin\x64\signtool.exe"
  )
  foreach ($p in $paths) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $root

Require-Tool flutter
Require-Tool wix
# wix extension add WixUIExtension (se hará en el script si es necesario)

$buildDir = Join-Path $root "build\windows\x64\runner\$Configuration"
$appExe = Join-Path $buildDir "mangopos.exe"
$stage = Join-Path $root "build\installer_stage"
$wixDir = Join-Path $root "installer\windows\wix"
$outDir = Join-Path $root "build\installer"
$msiPath = Join-Path $outDir "MangoPOS-Setup-1.0.0-x64.msi"

Write-Host "==> Building Flutter Windows app" -ForegroundColor Cyan
flutter build windows --release

if (-not (Test-Path $appExe)) {
  throw "No se encontró el ejecutable esperado: $appExe"
}

Write-Host "==> Building MangoPOS Print Agent" -ForegroundColor Cyan
Set-Location (Join-Path $root "agent")
npm run build:exe
Set-Location $root

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Copy-Item -Recurse -Force (Join-Path $buildDir "*") (Join-Path $stage "App")
# Copiar el payload completo del agente. El MSI ejecuta setup_pos.bat
# para registrar el wrapper de servicio correcto mediante node-windows.
New-Item -ItemType Directory -Force -Path (Join-Path $stage "Agent") | Out-Null
Copy-Item -Recurse -Force (Join-Path $root "agent\dist\*") (Join-Path $stage "Agent")
if (Test-Path (Join-Path $root "agent\config.yaml")) {
  Copy-Item -Force (Join-Path $root "agent\config.yaml") (Join-Path $stage "Agent")
}
# Copiar .env personalizado si existe. Si no, setup_pos.bat usara .env.example.
if (Test-Path (Join-Path $root "agent\.env")) {
  Copy-Item -Force (Join-Path $root "agent\.env") (Join-Path $stage "Agent")
}

Write-Host "==> Building MSI with WiX v7" -ForegroundColor Cyan
# Asegurar que la extension de UI esté instalada (para WiX 4 a 7+)
# En WiX v4+ se usan paquetes NuGet para las extensiones
try { & wix -acceptEula wix7 extension add WixToolset.UI.wixext --global } catch { }
try { & wix -acceptEula wix7 extension add WixToolset.Util.wixext --global } catch { }

$wixArgs = @(
  "build",
  "-acceptEula", "wix7",
  "-d", "SourceDir=$stage",
  "-d", "Version=1.0.0",
  "-d", "Manufacturer=Cristian Gomez",
  "-d", "ProductName=MangoPOS",
  "-ext", "WixToolset.UI.wixext",
  "-ext", "WixToolset.Util.wixext",
  "-o", $msiPath,
  (Join-Path $wixDir "Product.wxs")
)
& wix @wixArgs

if (-not (Test-Path $msiPath)) {
  throw "No se pudo generar MSI"
}

if (-not $SkipSign) {
  $signtool = Find-SignTool
  if (-not $signtool) {
    throw "No se encontró signtool.exe. Instala Windows SDK."
  }
  if ([string]::IsNullOrWhiteSpace($CertPfx)) {
    throw "Debes indicar -CertPfx para firmar el MSI."
  }

  Write-Host "==> Signing MSI" -ForegroundColor Cyan
  & $signtool sign /fd SHA256 /f $CertPfx /p $CertPassword /tr http://timestamp.digicert.com /td SHA256 $msiPath
}

Write-Host "MSI listo: $msiPath" -ForegroundColor Green
