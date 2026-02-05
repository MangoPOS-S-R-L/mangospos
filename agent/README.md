# MangoPOS Print Agent

Este es el agente local que gestiona la comunicación con las impresoras físicas. Se ejecuta como un servicio de Windows para asegurar que siempre esté disponible.

## Instalación Automática (Recomendada)

Simplemente ejecuta el archivo instalador incluido:

1.  Haz doble clic en **`setup.bat`**.
2.  El script verificará e instalará Node.js si falta (o te pedirá instalarlo).
3.  Instalará las dependencias necesarias.
4.  Creará el **Servicio de Windows** para que el agente inicie automáticamente con el sistema.

## Gestión del Servicio

*   **Detener/Desinstalar**: Ejecuta `uninstall.bat`.
*   **Logs**: Revisa el archivo `agent.log` en esta carpeta para ver el historial de impresión y errores.

## Configuración Manual

Si prefieres hacerlo manualmente:

1.  Instala Node.js.
2.  `npm install`
3.  Configura `.env` (se crea un ejemplo automáticamente con el setup).
4.  Para iniciar como servicio: `node install_service.js`
5.  Para iniciar consola (dev): `npm start`

## Dependencias de Hardware (Impresoras USB)

Para usar impresoras USB en Windows a través del modo RAW:

1.  Descarga **[Zadig](https://zadig.akeo.ie/)**.
2.  Conecta tu impresora USB.
3.  Abre Zadig > Options > List All Devices.
4.  Selecciona tu impresora.
5.  Instala el driver **WinUSB** (o libusb-win32).

*Nota: Para impresoras de red (Ethernet/WiFi), esto no es necesario.*

## Estructura

*   `src/index.js`: Lógica principal.
*   `install_service.js`: Script de registro del servicio de Windows.
