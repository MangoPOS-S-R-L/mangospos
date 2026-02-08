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
