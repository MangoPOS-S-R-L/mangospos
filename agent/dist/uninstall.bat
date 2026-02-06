@echo off
setlocal
cd /d "%~dp0"
TITLE MangoPOS Agent Uninstaller
COLOR 0C

echo ==================================================
echo       MANGO POS AGENT - DESINSTALADOR
echo ==================================================
echo.

:: Check Admin Privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Este script requiere privilegios de ADMINISTRADOR.
    echo Por favor, haz clic derecho y selecciona "Ejecutar como administrador".
    pause
    exit /b 1
)

echo Desinstalando el servicio de Windows...
node uninstall_service.js

echo.
echo ==================================================
echo       DESINSTALACION COMPLETADA
echo ==================================================
pause
