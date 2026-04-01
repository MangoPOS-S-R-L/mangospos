param(
  [string]$Configuration = "Release",
  [string]$Platform = "x64",
  [string]$AppVersion = "",
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

function Normalize-AppVersion([string]$Version) {
  if ([string]::IsNullOrWhiteSpace($Version)) {
    return "1.0.0"
  }

  $versionText = $Version.Trim()
  $match = [regex]::Match($versionText, '^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$')
  if (-not $match.Success) {
    return $versionText
  }

  $major = $match.Groups[1].Value
  $minor = $match.Groups[2].Value
  $patch = $match.Groups[3].Value
  $build = $match.Groups[4].Value

  if ([string]::IsNullOrWhiteSpace($build)) {
    return "$major.$minor.$patch"
  }

  return "$major.$minor.$patch.$build"
}

function Get-AppVersionFromPubspec([string]$PubspecPath) {
  if (-not (Test-Path $PubspecPath)) {
    return "1.0.0"
  }

  $match = Select-String -Path $PubspecPath -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9]+)?)' | Select-Object -First 1
  if ($match) {
    return Normalize-AppVersion $match.Matches[0].Groups[1].Value
  }

  return "1.0.0"
}

function Copy-WindowsRuntimeDependencies([string]$Destination) {
  $system32 = Join-Path $Env:windir "System32"
  $runtimeFiles = @(
    "vcruntime140.dll",
    "vcruntime140_1.dll",
    "vcruntime140_threads.dll",
    "msvcp140.dll",
    "msvcp140_1.dll",
    "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll",
    "msvcp140_codecvt_ids.dll",
    "concrt140.dll"
  )

  foreach ($file in $runtimeFiles) {
    $source = Join-Path $system32 $file
    if (Test-Path $source) {
      Copy-Item -Force $source (Join-Path $Destination $file)
    } else {
      Write-Warning "No se encontro runtime requerido en System32: $file"
    }
  }
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $root

Require-Tool flutter
Require-Tool wix
# wix extension add WixUIExtension (se hará en el script si es necesario)

$resolvedVersion = if ([string]::IsNullOrWhiteSpace($AppVersion)) {
  Get-AppVersionFromPubspec (Join-Path $root "pubspec.yaml")
} else {
  Normalize-AppVersion $AppVersion
}

$buildDir = Join-Path $root "build\windows\x64\runner\$Configuration"
$appExe = Join-Path $buildDir "mangopos.exe"
$stage = Join-Path $root "build\installer_stage"
$wixDir = Join-Path $root "installer\windows\wix"
$outDir = Join-Path $root "build\installer"
$msiPath = Join-Path $outDir "MangoPOS-Setup-$resolvedVersion-x64.msi"

Write-Host "==> Building Flutter Windows app" -ForegroundColor Cyan
flutter build windows --release

if (-not (Test-Path $appExe)) {
  throw "No se encontró el ejecutable esperado: $appExe"
}

Write-Host "==> Building MangoPOS Print Agent" -ForegroundColor Cyan
Set-Location (Join-Path $root "agent")
npm run build:exe
Set-Location $root

if (Test-Path $stage) {
    Write-Host "==> Cleaning installer stage" -ForegroundColor Gray
    try { Remove-Item $stage -Recurse -Force -ErrorAction Stop } catch {
        # Si falló por archivo bloqueado, intentamos un rename o esperar
        Move-Item $stage (Join-Path $Env:TEMP "stage_old_$([Guid]::NewGuid().ToString().Substring(0,8))") -Force -ErrorAction SilentlyContinue
    }
}
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage "App") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage "Agent") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage "Support") | Out-Null

Write-Host "==> Preparing App stage (Robocopy)" -ForegroundColor Cyan
# Robocopy es mas fiable para mantener la estructura de carpetas (especialmente 'data')
& robocopy $buildDir (Join-Path $stage "App") /e /np /njh /njs /log:null
Copy-WindowsRuntimeDependencies (Join-Path $stage "App")

Write-Host "==> Preparing Agent stage" -ForegroundColor Cyan
# Copiar solo el payload necesario del agente
Copy-Item -Force (Join-Path $root "agent\dist\mangopos-agent.exe") (Join-Path $stage "Agent\mangopos-agent.exe")
if (Test-Path (Join-Path $root "agent\config.yaml")) {
  Copy-Item -Force (Join-Path $root "agent\config.yaml") (Join-Path $stage "Agent")
}
# Copiar .env personalizado si existe. Si no, usamos .env.example como plantilla para el instalador.
if (Test-Path (Join-Path $root "agent\.env")) {
  Copy-Item -Force (Join-Path $root "agent\.env") (Join-Path $stage "Agent")
} elseif (Test-Path (Join-Path $root "agent\.env.example")) {
  Copy-Item -Force (Join-Path $root "agent\.env.example") (Join-Path $stage "Agent\.env")
}

# Copiar el wrapper de servicio WinSW y su configuracion XML
Copy-Item -Force (Join-Path $root "installer\windows\mangopos-agent-service.xml") (Join-Path $stage "Agent")
Copy-Item -Force (Join-Path $root "installer\windows\WinSW.exe") (Join-Path $stage "Agent\mangopos-agent-service.exe")

Write-Host "==> Preparing Support tools" -ForegroundColor Cyan
& robocopy (Join-Path $root "installer\windows\support") (Join-Path $stage "Support") /e /np /njh /njs /log:null

Write-Host "==> Building MSI with WiX v7" -ForegroundColor Cyan

# Asegurar que la extension de UI esté instalada (para WiX 4 a 7+)
try { & wix -acceptEula wix7 extension add WixToolset.UI.wixext --global } catch { }
try { & wix -acceptEula wix7 extension add WixToolset.Util.wixext --global } catch { }

$wixArgs = @(
  "build",
  "-acceptEula", "wix7",
  "-d", "SourceDir=$stage",
  "-d", "Version=$resolvedVersion",
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
    Write-Warning "No se encontró signtool.exe. Se omitirá la firma digital."
  }
  elseif ([string]::IsNullOrWhiteSpace($CertPfx)) {
    Write-Warning "Certificado no proporcionado. Se omitirá la firma digital."
  }
  else {
    Write-Host "==> Signing MSI" -ForegroundColor Cyan
    & $signtool sign /fd SHA256 /f $CertPfx /p $CertPassword /tr http://timestamp.digicert.com /td SHA256 $msiPath
  }
}

Write-Host "MSI listo: $msiPath" -ForegroundColor Green

# --- Inno Setup (Nueva Opción para Solucionar Truncado) ---
$iscc = Join-Path $Env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"
if (Test-Path $iscc) {
    Write-Host "==> Building Inno Setup EXE (Recomendado)" -ForegroundColor Cyan
    & $iscc "/DAppVersion=$resolvedVersion" (Join-Path $PSScriptRoot "mangopos.iss")
    Write-Host "EXE listo en build/installer/" -ForegroundColor Green
}
