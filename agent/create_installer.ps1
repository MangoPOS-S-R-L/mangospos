$ErrorActionPreference = "Stop"

# Auto-Elevate to Administrator
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process PowerShell -Verb RunAs "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Exit
}

Write-Host "Running as Administrator." -ForegroundColor Green

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "   MangoPOS Print Agent Installer v2.0   " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# 1. Dependency Check (Node.js)
Write-Host "`n[1/5] Checking Dependencies..."
try {
    $nodeVer = node --version
    Write-Host "Node.js detected: $nodeVer" -ForegroundColor Green
} catch {
    Write-Host "Node.js NOT found! Please install Node.js (LTS) first." -ForegroundColor Red
    Start-Process "https://nodejs.org/"
    Exit
}

# 2. Setup Directory
$installDir = "C:\MangoPOS\Agent"
Write-Host "`n[2/5] Setting up installation at $installDir..."

if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Write-Host "Created directory."
}

# Copy files from current dev location (Assuming script run from repo source)
# Adjust these paths if bundling differently
$sourceDir = "$PSScriptRoot\src"
$configFile = "$PSScriptRoot\config.yaml"
$packageFile = "$PSScriptRoot\package.json"
$publicDir = "$PSScriptRoot\public"

if (!(Test-Path $sourceDir)) {
    Write-Host "Error: Source files not found in $PSScriptRoot" -ForegroundColor Red
    Exit
}

Copy-Item -Recurse -Force "$PSScriptRoot\src" $installDir
Copy-Item -Recurse -Force "$PSScriptRoot\scripts" $installDir
Copy-Item -Force "$PSScriptRoot\package.json" $installDir
Copy-Item -Recurse -Force "$PSScriptRoot\public" $installDir

if (-not (Test-Path "$installDir\config.yaml")) {
    if (Test-Path $configFile) {
        Copy-Item -Force $configFile "$installDir\config.yaml"
    } else {
        Write-Host "Creating default config..."
        Set-Content -Path "$installDir\config.yaml" -Value "service:`n  port: 9100`nsecurity:`n  enabled: true`n  api_token: 'MANGOPOS_SECURE_TOKEN_123'`nprinters: []"
    }
}

# 3. Install NPM Dependencies
Write-Host "`n[3/5] Installing Packages..."
Set-Location $installDir
npm install --production --no-audit --no-fund

# 4. Firewall Rule
Write-Host "`n[4/5] Configuring Firewall..."
$fwName = "MangoPOS Agent (9100)"
Remove-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $fwName -Direction Inbound -LocalPort 9100 -Protocol TCP -Action Allow -Profile Any | Out-Null
Write-Host "Firewall rule added for Port 9100" -ForegroundColor Green

# 5. Service Installation
Write-Host "`n[5/5] Registering Windows Service..."
# Uninstall first to be safe
try { node scripts/uninstall_service.js } catch {}
Start-Sleep -Seconds 2
node scripts/install_service.js

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "   INSTALLATION COMPLETE!   " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Agent is running on Port 9100"
Write-Host "Admin UI: http://localhost:9100"
Start-Sleep -Seconds 5
