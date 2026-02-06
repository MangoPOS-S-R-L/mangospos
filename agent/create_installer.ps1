# Script para crear un instalador portátil del Agente de MangoPOS
$ErrorActionPreference = "Stop"

$sourceDir = "d:\MangoPos\Dev\mangopos\agent"
$distDir =Join-Path $sourceDir "dist"
$nodePath = "C:\Program Files\nodejs\node.exe"

echo "=== Creando Instalador Portatil ==="

# 1. Limpiar/Crear dist
if (Test-Path $distDir) {
    Remove-Item -Recurse -Force $distDir
}
New-Item -ItemType Directory -Path $distDir | Out-Null
New-Item -ItemType Directory -Path (Join-Path $distDir "src") | Out-Null

# 2. Copiar archivos base
echo "[1/4] Copiando archivos base..."
Copy-Item -Path (Join-Path $sourceDir "src\*") -Destination (Join-Path $distDir "src") -Recurse
Copy-Item -Path (Join-Path $sourceDir "package.json") -Destination $distDir
Copy-Item -Path (Join-Path $sourceDir "install_service.js") -Destination $distDir
Copy-Item -Path (Join-Path $sourceDir "uninstall_service.js") -Destination $distDir
Copy-Item -Path (Join-Path $sourceDir "uninstall.bat") -Destination $distDir
Copy-Item -Path (Join-Path $sourceDir ".env") -Destination (Join-Path $distDir ".env.example") # Como ejemplo

# 3. Copiar node_modules (Es pesado pero garantiza que funcione sin internet)
echo "[2/4] Copiando dependencias (node_modules)..."
Copy-Item -Path (Join-Path $sourceDir "node_modules") -Destination $distDir -Recurse

# 4. Copiar Node.js ejecutable
echo "[3/4] Incluyendo motor Node.js..."
Copy-Item -Path $nodePath -Destination $distDir

# 5. Crear setup_portatil.bat
echo "[4/4] Creando script de instalacion..."
$setupBat = @"
@echo off
TITLE MangoPOS Agent - Instalador Portatil
cd /d "%~dp0"

echo ==================================================
echo       MANGO POS AGENT - INSTALACION
echo ==================================================
echo.

:: Check Admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Por favor, ejecuta este archivo como ADMINISTRADOR.
    echo Haz clic derecho y selecciona "Ejecutar como administrador".
    pause
    exit /b 1
)

:: Crear .env si no existe
if not exist .env (
    echo [INFO] Configurando .env por defecto...
    copy .env.example .env
)

echo [INFO] Instalando servicio de Windows...
.\node.exe install_service.js

echo.
echo ==================================================
echo [LISTO] El agente se ha instalado correctamente.
echo ==================================================
pause
"@
$setupBat | Out-File -FilePath (Join-Path $distDir "setup_pos.bat") -Encoding ASCII

echo "[INFO] Comprimiendo en MangoPOS-Agent.zip..."
$zipPath = Join-Path $sourceDir "MangoPOS-Agent.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path "$distDir\*" -DestinationPath $zipPath

echo ""
echo "=== PROCESO COMPLETADO ==="
echo "Se ha generado el archivo: MangoPOS-Agent.zip"
echo ""
echo "Instrucciones para la otra maquina:"
echo "1. Copia 'MangoPOS-Agent.zip' a la maquina de destino."
echo "2. Descomprimelo en una carpeta (ej: C:\MangoPOS-Agent)."
echo "3. Ejecuta 'setup_pos.bat' como Administrador."
echo ""
