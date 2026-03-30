param(
  [string]$OutputName = "MangoPOS-Agent-Uninstall.exe"
)

$ErrorActionPreference = "Stop"

function Require-Tool([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Falta herramienta requerida: $Name"
  }
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$source = Join-Path $root "tools\agent_uninstaller.dart"
$outDir = Join-Path $root "build\installer"
$output = Join-Path $outDir $OutputName

if (-not (Test-Path $source)) {
  throw "No se encontro la fuente del desinstalador: $source"
}

Require-Tool dart
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "==> Building MangoPOS Agent uninstaller" -ForegroundColor Cyan
dart compile exe $source -o $output

if (-not (Test-Path $output)) {
  throw "No se genero el ejecutable esperado: $output"
}

Write-Host "Desinstalador listo: $output" -ForegroundColor Green
