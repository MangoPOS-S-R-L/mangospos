param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('caja', 'mesero')]
  [string]$Role,
  [ValidateRange(30, 3600)]
  [int]$DurationSeconds = 300,
  [ValidateRange(1, 60)]
  [int]$IntervalSeconds = 5,
  [string]$OutputDirectory = '.'
)

$ErrorActionPreference = 'Stop'
$process = Get-Process -Name 'mangopos' -ErrorAction Stop |
  Sort-Object StartTime -Descending | Select-Object -First 1
$pidToMeasure = $process.Id
$cores = [Environment]::ProcessorCount
$started = Get-Date
$previousTime = $started
$previousCpu = [double]$process.CPU
$samples = [System.Collections.Generic.List[object]]::new()
$path = Join-Path $OutputDirectory (
  'mangopos-{0}-{1}.csv' -f $Role, $started.ToString('yyyyMMdd-HHmmss')
)

Write-Host "Midiendo mangopos PID $pidToMeasure durante $DurationSeconds s..."
try {
  while (((Get-Date) - $started).TotalSeconds -lt $DurationSeconds) {
    Start-Sleep -Seconds $IntervalSeconds
    $current = Get-Process -Id $pidToMeasure -ErrorAction Stop
    $now = Get-Date
    $elapsed = ($now - $previousTime).TotalSeconds
    $cpuDelta = [Math]::Max(0, ([double]$current.CPU - $previousCpu))
    $cpuPercent = if ($elapsed -gt 0 -and $cores -gt 0) {
      [Math]::Round(100 * $cpuDelta / $elapsed / $cores, 2)
    } else { 0 }
    $samples.Add([pscustomobject]@{
      timestamp = $now.ToString('o')
      role = $Role
      process_id = $pidToMeasure
      cpu_percent_total = $cpuPercent
      working_set_mib = [Math]::Round($current.WorkingSet64 / 1MB, 2)
      private_memory_mib = [Math]::Round($current.PrivateMemorySize64 / 1MB, 2)
    })
    $previousTime = $now
    $previousCpu = [double]$current.CPU
  }
} finally {
  if ($samples.Count -gt 0) {
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $samples | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    Write-Host "Muestras: $($samples.Count). Archivo: $path"
  }
}
