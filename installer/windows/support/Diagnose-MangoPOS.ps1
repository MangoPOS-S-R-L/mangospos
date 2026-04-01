$ErrorActionPreference = 'Stop'

function Write-Section([string]$title) {
  Write-Host ""
  Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-HttpsEndpoint([string]$url) {
  try {
    $response = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 20
    [pscustomobject]@{
      Url = $url
      Ok = $true
      StatusCode = [int]$response.StatusCode
      Error = $null
    }
  } catch {
    [pscustomobject]@{
      Url = $url
      Ok = $false
      StatusCode = $null
      Error = $_.Exception.Message
    }
  }
}

$desktop = [Environment]::GetFolderPath('Desktop')
$logDir = Join-Path $desktop 'MangoPOS-Diagnostics'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logPath = Join-Path $logDir ("diagnostic-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".txt")

Start-Transcript -Path $logPath -Force | Out-Null
try {
  Write-Host "MangoPOS - Diagnostico de conectividad" -ForegroundColor Yellow
  Write-Host "Log: $logPath"

  Write-Section "Sistema"
  $os = Get-CimInstance Win32_OperatingSystem
  $cs = Get-CimInstance Win32_ComputerSystem
  Write-Host ("Equipo: {0}" -f $cs.Name)
  Write-Host ("Windows: {0} ({1})" -f $os.Caption, $os.Version)
  Write-Host ("Arquitectura: {0}" -f $os.OSArchitecture)
  Write-Host ("Hora local: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))

  Write-Section "Hora y sincronizacion"
  try {
    w32tm /query /status
  } catch {
    Write-Warning "No se pudo consultar el estado del servicio de hora: $($_.Exception.Message)"
  }

  Write-Section "Proxy"
  try {
    netsh winhttp show proxy
  } catch {
    Write-Warning "No se pudo consultar WinHTTP proxy: $($_.Exception.Message)"
  }

  try {
    $internetSettings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Write-Host ("ProxyEnable: {0}" -f $internetSettings.ProxyEnable)
    Write-Host ("ProxyServer: {0}" -f $internetSettings.ProxyServer)
    Write-Host ("AutoConfigURL: {0}" -f $internetSettings.AutoConfigURL)
  } catch {
    Write-Warning "No se pudo leer la configuracion de proxy del usuario: $($_.Exception.Message)"
  }

  Write-Section "HTTPS"
  @(
    'https://app.mangopos.do',
    'https://google.com',
    'https://api.github.com'
  ) | ForEach-Object {
    $result = Test-HttpsEndpoint $_
    if ($result.Ok) {
      Write-Host ("OK {0} -> {1}" -f $result.Url, $result.StatusCode) -ForegroundColor Green
    } else {
      Write-Host ("FAIL {0} -> {1}" -f $result.Url, $result.Error) -ForegroundColor Red
    }
  }

  Write-Section "Red"
  try {
    ipconfig /all
  } catch {
    Write-Warning "No se pudo obtener ipconfig: $($_.Exception.Message)"
  }

  Write-Section "Certificados de terceros sospechosos"
  try {
    Get-ChildItem Cert:\LocalMachine\Root |
      Where-Object {
        $_.Subject -match 'avast|avg|eset|kaspersky|bitdefender|zscaler|fortinet|sophos|checkpoint|proxy'
      } |
      Select-Object Subject, Thumbprint, NotAfter
  } catch {
    Write-Warning "No se pudo revisar el almacen de certificados: $($_.Exception.Message)"
  }

  Write-Host ""
  Write-Host "Diagnostico completado." -ForegroundColor Green
  Write-Host "Comparte este archivo si necesitas soporte: $logPath" -ForegroundColor Yellow
} finally {
  Stop-Transcript | Out-Null
}
