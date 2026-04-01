$ErrorActionPreference = 'Continue'

function Run-Step([string]$title, [scriptblock]$action) {
  Write-Host ""
  Write-Host "=== $title ===" -ForegroundColor Cyan
  try {
    & $action
    Write-Host "OK" -ForegroundColor Green
  } catch {
    Write-Warning $_.Exception.Message
  }
}

Write-Host "MangoPOS - Reparacion basica de red/TLS" -ForegroundColor Yellow
Write-Host "Esta utilidad aplica acciones seguras y no cambia antivirus ni certificados corporativos." -ForegroundColor Yellow

Run-Step "Habilitando e iniciando servicio de hora" {
  sc.exe config W32Time start= auto | Out-Null
  Start-Service W32Time -ErrorAction SilentlyContinue
}

Run-Step "Sincronizando reloj" {
  w32tm /resync /force
}

Run-Step "Vaciando cache DNS" {
  ipconfig /flushdns
}

Run-Step "Limpiando cache URL/certificados" {
  certutil -urlcache * delete
}

Run-Step "Reiniciando Winsock" {
  netsh winsock reset
}

Run-Step "Mostrando Windows Update" {
  Start-Process "ms-settings:windowsupdate"
}

Run-Step "Mostrando fecha y hora" {
  Start-Process "ms-settings:dateandtime"
}

Write-Host ""
Write-Host "La reparacion termino. Reinicia la PC antes de probar MangoPOS otra vez." -ForegroundColor Green
