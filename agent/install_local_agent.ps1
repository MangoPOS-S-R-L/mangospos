<# 
Instalador / configurador del Print Agent local.
Requisitos:
- Windows con PowerShell 5+
- Node.js y npm instalados
- Ejecutar como Administrador (para pm2 startup)

Pasos:
1) npm install
2) npm run setup (wizard de impresoras)
3) pm2 start npm --name mango-agent -- run start
4) pm2 save && pm2 startup windows
#>

param(
  [string]$AgentPath = "$PSScriptRoot",
  [switch]$Force,
  [switch]$BuildInstaller
)

function Ensure-Admin {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevando permisos..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = "runas"
    try {
      [System.Diagnostics.Process]::Start($psi) | Out-Null
      exit
    } catch {
      Write-Error "Necesitas ejecutar como Administrador (clic derecho > Run as administrator)."
      exit 1
    }
  }
}

function Ensure-Tool($cmd) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    Write-Error "$cmd no encontrado en PATH. Instala Node.js/npm antes de continuar."
    exit 1
  }
}

function Build-Installer($Source, $Target) {
  Write-Host "-> Generando carpeta de instalador en $Target" -ForegroundColor Cyan

  if (Test-Path $Target) {
    Remove-Item $Target -Recurse -Force
  }
  New-Item -ItemType Directory -Path $Target | Out-Null

  # Excluir carpetas pesadas o irrelevantes
  $exclude = @('node_modules', '.git', '.idea', '.vscode', 'dist', 'build', '.dart_tool')
  $excludeParams = $exclude | ForEach-Object { "/XD", $_ }

  & robocopy $Source $Target /E @excludeParams | Out-Null

  $zipPath = Join-Path (Split-Path $Target -Parent) "agent_installer.zip"
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  Compress-Archive -Path (Join-Path $Target '*') -DestinationPath $zipPath

  Write-Host "Instalador listo:" -ForegroundColor Green
  Write-Host "  Carpeta: $Target"
  Write-Host "  ZIP:     $zipPath"
}

function Has-NpmScript($name) {
  $pkg = Join-Path $AgentPath "package.json"
  if (-not (Test-Path $pkg)) { return $false }
  try {
    $json = Get-Content $pkg -Raw | ConvertFrom-Json
    return $json.scripts.$name -ne $null
  } catch { return $false }
}

function Get-MainEntry() {
  $pkg = Join-Path $AgentPath "package.json"
  if (-not (Test-Path $pkg)) { return $null }
  try {
    $json = Get-Content $pkg -Raw | ConvertFrom-Json
    if ($json.main) { return $json.main }
  } catch { return $null }
  return $null
}

Ensure-Admin
Ensure-Tool npm

Set-Location $AgentPath

if ($BuildInstaller) {
  $output = Join-Path $AgentPath "agent_installer"
  Build-Installer -Source $AgentPath -Target $output
  exit 0
}

Write-Host "-> Instalando dependencias npm..." -ForegroundColor Cyan
npm install
if ($LASTEXITCODE -ne 0 -and -not $Force) { exit 1 }

if (Has-NpmScript "setup") {
  Write-Host "-> Ejecutando wizard de setup (npm run setup)..." -ForegroundColor Cyan
  npm run setup
} else {
  Write-Host "-> Script npm \"setup\" no encontrado. Omitiendo este paso." -ForegroundColor Yellow
}

Write-Host "-> Verificando pm2..." -ForegroundColor Cyan
if (-not (Get-Command pm2 -ErrorAction SilentlyContinue)) {
  npm install -g pm2
}

Write-Host "-> Iniciando agente con pm2..." -ForegroundColor Cyan
$startScript = Has-NpmScript "start"
$mainEntry = Get-MainEntry
if ($startScript) {
  pm2 delete mango-agent 2>$null | Out-Null
  pm2 start npm --name mango-agent -- run start --cwd "$AgentPath"
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[ADVERTENCIA] pm2 no pudo lanzar npm run start (code $LASTEXITCODE). Intentando con node directo..." -ForegroundColor Yellow
    $startScript = $false
  }
} elseif ($mainEntry) {
  $mainPath = Join-Path $AgentPath $mainEntry
  pm2 delete mango-agent 2>$null | Out-Null
  pm2 start node --name mango-agent -- "$mainPath" --cwd "$AgentPath"
} else {
  Write-Host "[ADVERTENCIA] No se encontró script npm \"start\" ni campo \"main\" en package.json. No se inició pm2." -ForegroundColor Yellow
}

if (-not $startScript -and $mainEntry) {
  $mainPath = Join-Path $AgentPath $mainEntry
  pm2 delete mango-agent 2>$null | Out-Null
  pm2 start node --name mango-agent -- "$mainPath" --cwd "$AgentPath"
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] pm2 tampoco pudo iniciar con node $mainPath" -ForegroundColor Red
  } else {
    Write-Host "-> pm2 iniciado con node $mainPath" -ForegroundColor Green
  }
}

Write-Host "-> Guardando proceso y creando servicio de arranque..." -ForegroundColor Cyan
pm2 save
pm2 startup windows | Out-Null

Write-Host ""
Write-Host "Listo. El agente escuchará en http://127.0.0.1:9105" -ForegroundColor Green
Write-Host "Comandos útiles:"
Write-Host "  pm2 ls              # ver estado"
Write-Host "  pm2 logs mango-agent # ver logs"
Write-Host "  pm2 restart mango-agent"
Write-Host ""
