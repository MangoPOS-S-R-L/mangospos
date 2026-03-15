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
Require-Tool candle
Require-Tool light

$buildDir = Join-Path $root "build\windows\x64\runner\$Configuration"
$appExe = Join-Path $buildDir "mangopos.exe"
$agentSrc = Join-Path $root "agent"
$stage = Join-Path $root "build\installer_stage"
$wixDir = Join-Path $root "installer\windows\wix"
$outDir = Join-Path $root "build\installer"
$msiPath = Join-Path $outDir "MangoPOS-Setup-1.0.0-x64.msi"

Write-Host "==> Building Flutter Windows app" -ForegroundColor Cyan
flutter build windows --release

if (-not (Test-Path $appExe)) {
  throw "No se encontró el ejecutable esperado: $appExe"
}

Write-Host "==> Preparing installer stage" -ForegroundColor Cyan
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Copy-Item -Recurse -Force (Join-Path $buildDir "*") (Join-Path $stage "App")
Copy-Item -Recurse -Force $agentSrc (Join-Path $stage "Agent")

Write-Host "==> Building MSI with WiX" -ForegroundColor Cyan
$candleArgs = @(
  "-dSourceDir=$stage",
  "-dVersion=1.0.0",
  "-dManufacturer=Cristian Gomez",
  "-dProductName=MangoPOS",
  "-out", (Join-Path $outDir "MangoPOS.wixobj"),
  (Join-Path $wixDir "Product.wxs")
)
& candle @candleArgs

$lightArgs = @(
  "-ext", "WixUIExtension",
  "-ext", "WixUtilExtension",
  "-out", $msiPath,
  (Join-Path $outDir "MangoPOS.wixobj")
)
& light @lightArgs

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
