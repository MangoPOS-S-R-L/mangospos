<# 
Listar impresoras USB (service=usbprint) usando CIM (más estable que Get-WmiObject).
Devuelve JSON con Name, PNPDeviceID y Manufacturer.
#>

try {
  $items = Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.Service -eq 'usbprint' } |
    Select-Object Name, PNPDeviceID, Manufacturer

  $items | ConvertTo-Json -Depth 3
} catch {
  Write-Error $_
  exit 1
}
