param(
  [switch]$Clean,
  [switch]$Verbose
)

$ErrorActionPreference = "Stop"

function Stop-IfRunning([string]$ProcessName) {
  $procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
  if (-not $procs) { return }
  try {
    $procs | Stop-Process -Force -ErrorAction Stop
    Write-Host "Stopped process: $ProcessName" -ForegroundColor Gray
  } catch {
    Write-Warning "Could not stop process $ProcessName: $($_.Exception.Message)"
  }
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $root

Stop-IfRunning "mangopos"
Start-Sleep -Milliseconds 250

if ($Clean) {
  Write-Host "==> flutter clean" -ForegroundColor Cyan
  flutter clean
}

$args = @("run", "-d", "windows", "--no-dds")
if ($Verbose) { $args += "-v" }

Write-Host "==> flutter $($args -join ' ')" -ForegroundColor Cyan
& flutter @args

