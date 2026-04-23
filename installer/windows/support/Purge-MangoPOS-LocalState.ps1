$ErrorActionPreference = 'SilentlyContinue'

$relativePaths = @(
    'AppData\Roaming\com.example\mangopos\shared_preferences.json',
    'AppData\Local\com.example\mangopos\shared_preferences.json',
    'Desktop\mangopos_startup.log',
    'Desktop\mangopos_dart.log',
    'OneDrive\Desktop\mangopos_startup.log',
    'OneDrive\Desktop\mangopos_dart.log'
)

$usersRoot = 'C:\Users'
if (-not (Test-Path $usersRoot)) { exit 0 }

Get-ChildItem -Path $usersRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($rel in $relativePaths) {
        $target = Join-Path $_.FullName $rel
        if (Test-Path $target) {
            Remove-Item -Path $target -Force -ErrorAction SilentlyContinue
        }
    }
}

exit 0
