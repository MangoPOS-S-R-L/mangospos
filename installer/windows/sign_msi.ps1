param(
  [Parameter(Mandatory=$true)][string]$MsiPath,
  [Parameter(Mandatory=$true)][string]$CertPfx,
  [Parameter(Mandatory=$true)][string]$CertPassword
)

$ErrorActionPreference = "Stop"

$signToolCandidates = @(
  "$Env:ProgramFiles (x86)\Windows Kits\10\bin\x64\signtool.exe",
  "$Env:ProgramFiles\Windows Kits\10\bin\x64\signtool.exe"
)

$signtool = $signToolCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $signtool) {
  throw "No se encontró signtool.exe"
}

& $signtool sign /fd SHA256 /f $CertPfx /p $CertPassword /tr http://timestamp.digicert.com /td SHA256 $MsiPath
Write-Host "Firmado: $MsiPath" -ForegroundColor Green
