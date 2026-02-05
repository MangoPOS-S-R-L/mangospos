@echo off
setlocal enableextensions enabledelayedexpansion
cd /d "%~dp0"

TITLE MangoPOS Agent Installer
COLOR 0A

echo ==================================================
echo       MANGO POS AGENT - INSTALADOR
echo ==================================================
echo.

:: 0. Check Administrator Privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Este script requiere privilegios de ADMINISTRADOR.
    echo Por favor, haz clic derecho y selecciona "Ejecutar como administrador".
    pause
    exit /b 1
)

:: 1. Verificar Node.js
echo [1/4] Verificando instalacion de Node.js...
node -v
if %errorlevel% neq 0 (
    echo [ALERTA] Node.js no parece estar en el PATH.
    echo Asegurate de tenerlo instalado. Continuaremos de todos modos...
)
echo.

:: 2. Instalar Dependencias
echo [2/4] Instalando dependencias (npm install)...
call npm install --omit=dev
if %errorlevel% neq 0 (
    echo [ERROR] Fallo al instalar dependencias.
    pause
    exit /b 1
)
echo [OK] Dependencias instaladas.
echo.

:: 3. Configurar Variables de Entorno
if not exist .env (
    echo [3/4] Creando configuracion inicial (.env)...
    echo BACKEND_URL=http://localhost:3000 > .env
    echo AGENT_ID=pos-agent-%RANDOM% >> .env
    echo AGENT_NAME=Caja-%COMPUTERNAME% >> .env
    echo LOG_LEVEL=info >> .env
    echo [OK] Archivo .env creado.
) else (
    echo [3/4] Configuracion encontrada (.env).
)
echo.

:: 4. Instalar Servicio de Windows
echo [4/4] Configurando inicio automatico (Servicio de Windows)...
echo.
node install_service.js

echo.
echo ==================================================
echo       RECORDATORIO IMPORTANTE DE HARDWARE
echo ==================================================
echo Si vas a usar IMPRESORAS USB:
echo 1. Debes instalar el driver WinUSB para tu impresora.
echo 2. Descarga Zadig: https://zadig.akeo.ie/
echo 3. Abre Zadig, selecciona tu impresora y dale a "Install Driver".
echo.
echo Si usas IMPRESORAS DE RED (Ethernet/WiFi), no es necesario.
echo ==================================================
echo.
echo [COMPLETADO] El agente se ha instalado y esta corriendo.
echo.
pause
