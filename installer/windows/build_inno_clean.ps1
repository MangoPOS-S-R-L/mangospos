param(
  [string]$Configuration = "Release",
  [string]$AppVersion = "",
  [switch]$Fast
)

$ErrorActionPreference = "Stop"

function Require-Tool([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Falta herramienta requerida: $Name"
  }
}

function Remove-OrQuarantine([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  try {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    return
  } catch {
    $quarantineRoot = Join-Path $Env:TEMP "mangopos_clean_$([Guid]::NewGuid().ToString().Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $quarantineRoot | Out-Null
    $dest = Join-Path $quarantineRoot (Split-Path -Leaf $Path)
    Move-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction SilentlyContinue
  }
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $root

Require-Tool flutter

Write-Host "==> Flutter clean" -ForegroundColor Cyan
flutter clean

if (-not $Fast) {
  Write-Host "==> Cleaning build artifacts" -ForegroundColor Cyan
  Remove-OrQuarantine (Join-Path $root "build\windows")
  Remove-OrQuarantine (Join-Path $root "build\installer_stage")
  Remove-OrQuarantine (Join-Path $root "build\installer")
  Remove-OrQuarantine (Join-Path $root ".dart_tool")
}

Write-Host "==> Flutter pub get" -ForegroundColor Cyan
flutter pub get

$agentDir = Join-Path $root "agent"
if (Test-Path -LiteralPath $agentDir) {
  Require-Tool npm

  Write-Host "==> Cleaning agent artifacts" -ForegroundColor Cyan
  Remove-OrQuarantine (Join-Path $agentDir "dist")

  if (-not $Fast) {
    Remove-OrQuarantine (Join-Path $agentDir "node_modules")
  }

  $nodeModules = Join-Path $agentDir "node_modules"
  if (-not (Test-Path -LiteralPath $nodeModules)) {
    Set-Location $agentDir
    Write-Host "==> npm ci (agent)" -ForegroundColor Cyan
    npm ci
    if ($LASTEXITCODE -ne 0) {
      throw "Fallo npm ci en agent"
    }
    Set-Location $root
  }
}

$args = @{
  Configuration = $Configuration
}

if (-not [string]::IsNullOrWhiteSpace($AppVersion)) {
  $args["AppVersion"] = $AppVersion
}

Write-Host "==> Building Inno Setup installer (clean)" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "build_inno.ps1") @args

