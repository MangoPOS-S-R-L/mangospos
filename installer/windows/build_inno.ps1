param(
  [string]$Configuration = "Release",
  [string]$AppVersion = "",
  [switch]$SkipFlutterBuild,
  [switch]$SkipAgentBuild,
  [switch]$SkipStage
)

$ErrorActionPreference = "Stop"

function Require-Tool([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Falta herramienta requerida: $Name"
  }
}

function Resolve-InnoCompiler {
  $candidates = @(
    (Join-Path $Env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
    (Join-Path $Env:ProgramFiles "Inno Setup 6\ISCC.exe"),
    (Join-Path ${Env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe")
  )

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
      return $candidate
    }
  }

  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }

  throw "No se encontro ISCC.exe. Instala Inno Setup 6."
}

function Get-AppVersionFromPubspec([string]$PubspecPath) {
  if (-not (Test-Path $PubspecPath)) {
    return "1.0.0"
  }

  $match = Select-String -Path $PubspecPath -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
  if ($match) {
    return $match.Matches[0].Groups[1].Value
  }

  return "1.0.0"
}

function Copy-Directory([string]$Source, [string]$Destination) {
  if (-not (Test-Path $Source)) {
    throw "No se encontro la carpeta requerida: $Source"
  }

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  & robocopy $Source $Destination /E /NP /NJH /NJS /NFL /NDL /LOG:NUL | Out-Null

  if ($LASTEXITCODE -ge 8) {
    throw "Robocopy fallo al copiar $Source -> $Destination"
  }
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $root

$resolvedVersion = if ([string]::IsNullOrWhiteSpace($AppVersion)) {
  Get-AppVersionFromPubspec (Join-Path $root "pubspec.yaml")
} else {
  $AppVersion
}

$buildDir = Join-Path $root "build\windows\x64\runner\$Configuration"
$appExe = Join-Path $buildDir "mangopos.exe"
$agentExe = Join-Path $root "agent\dist\mangopos-agent.exe"
$stage = Join-Path $root "build\installer_stage"
$stageApp = Join-Path $stage "App"
$stageAgent = Join-Path $stage "Agent"
$outDir = Join-Path $root "build\installer"
$issPath = Join-Path $PSScriptRoot "mangopos.iss"
$iscc = Resolve-InnoCompiler

Require-Tool robocopy

if (-not $SkipFlutterBuild) {
  Require-Tool flutter
  Write-Host "==> Building Flutter Windows app" -ForegroundColor Cyan
  flutter build windows --release
}

if (-not (Test-Path $appExe)) {
  throw "No se encontro el ejecutable esperado: $appExe"
}

if (-not $SkipAgentBuild) {
  Require-Tool npm
  Write-Host "==> Building MangoPOS LAN agent" -ForegroundColor Cyan
  Set-Location (Join-Path $root "agent")
  npm run build:exe
  if ($LASTEXITCODE -ne 0) {
    throw "Fallo la compilacion del agente LAN"
  }
  Set-Location $root
}

if (-not (Test-Path $agentExe)) {
  throw "No se encontro el ejecutable esperado del agente: $agentExe"
}

if (-not $SkipStage) {
  if (Test-Path $stage) {
    Write-Host "==> Cleaning installer stage" -ForegroundColor Gray
    Remove-Item $stage -Recurse -Force
  }

  New-Item -ItemType Directory -Force -Path $stageApp | Out-Null
  New-Item -ItemType Directory -Force -Path $stageAgent | Out-Null
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null

  Write-Host "==> Preparing App stage" -ForegroundColor Cyan
  Copy-Directory $buildDir $stageApp

  Write-Host "==> Preparing Agent stage" -ForegroundColor Cyan
  Copy-Item -Force $agentExe (Join-Path $stageAgent "mangopos-agent.exe")
  Copy-Item -Force (Join-Path $root "agent\config.yaml") $stageAgent

  $envPath = Join-Path $root "agent\.env"
  if (Test-Path $envPath) {
    Copy-Item -Force $envPath $stageAgent
  }

  Copy-Item -Force (Join-Path $root "installer\windows\mangopos-agent-service.xml") $stageAgent
  Copy-Item -Force (Join-Path $root "installer\windows\WinSW.exe") (Join-Path $stageAgent "mangopos-agent-service.exe")
}

if (-not (Test-Path $stageApp)) {
  throw "No existe el stage de la app: $stageApp"
}

if (-not (Test-Path $stageAgent)) {
  throw "No existe el stage del agente: $stageAgent"
}

Write-Host "==> Building Inno Setup installer" -ForegroundColor Cyan
& $iscc "/DAppVersion=$resolvedVersion" $issPath

if ($LASTEXITCODE -ne 0) {
  throw "ISCC.exe devolvio un codigo de error: $LASTEXITCODE"
}

$installerPath = Join-Path $outDir "MangoPOS-Setup-$resolvedVersion-x64.exe"
if (-not (Test-Path $installerPath)) {
  throw "No se encontro el instalador esperado: $installerPath"
}

Write-Host "Instalador listo: $installerPath" -ForegroundColor Green
