# Build del agente para Windows + impresión USB en LAN

Esta guía cubre el flujo completo para que una impresora USB conectada a la PC
"host" sea utilizable desde otras máquinas (tablets, otras PCs) en la misma red
local.

Resumen del flujo:

```
[Tablet/PC remota] --HTTP--> [PC host:4000 (agente)] --USB--> [Impresora térmica]
```

Para que esto funcione hacen falta cuatro cosas:

1. **Build del instalador** con Inno Setup (incluye el `.exe` del agente con
   binarios nativos de Windows).
2. En la PC host: driver **WinUSB** instalado en la impresora (Zadig).
3. En la PC host: puerto `4000` abierto en el firewall.
4. Agente corriendo como servicio (lo registra el instalador) y publicando su
   IP LAN en `device_agents.agent_url` (lo hace solo la app Flutter al hacer
   heartbeat).

---

## 1. Build del instalador (flujo oficial)

El build de producción se genera con Inno Setup vía
[installer/windows/build_inno.ps1](../installer/windows/build_inno.ps1). Ese
script:

- Compila la app Flutter (`flutter build windows --release`).
- Compila el agente (`npm run build:exe` dentro de `agent/`).
- Stage en `build/installer_stage/` (carpetas `App`, `Agent`, `Support`).
- Bundlea WinSW como `mangopos-agent-service.exe` para registrar el agente
  como servicio de Windows.
- Compila el `.exe` final con `ISCC.exe` en `build/installer/`.

### Requisitos en la máquina de build

- Windows x64.
- **Node.js 18 LTS** (`node --version` → `v18.x`). Imprescindible para que el
  binario nativo `usb` se incluya correctamente. Si compilás en Mac/Linux el
  `.exe` falla en runtime con
  `No native build was found for platform=win32 arch=x64 ...`.
- Flutter SDK en PATH.
- **Inno Setup 6** (`ISCC.exe`) — https://jrsoftware.org/isdl.php.
- (Opcional) Certificado `.pfx` para firmar.

### Comando

```powershell
cd installer/windows
powershell -ExecutionPolicy Bypass -File .\build_inno.ps1
```

Si querés saltar pasos para iterar más rápido (ya tenés stage previo):

```powershell
powershell -ExecutionPolicy Bypass -File .\build_inno.ps1 `
  -SkipFlutterBuild -SkipAgentBuild -SkipStage
```

Salida: `build\installer\MangoPOS-Setup-<version>-x64.exe`.

### Solo el agente (dev iteration)

Si estás iterando sobre el agente y no querés rebuilear todo el instalador:

```cmd
cd agent
rd /s /q node_modules
npm install
npm run build:exe
```

Genera `agent\dist\mangopos-agent.exe`. El instalador lo toma desde ahí.

---

## 2. Driver WinUSB en la impresora (CRÍTICO en cada PC host)

Este paso se hace en la **máquina donde se conecta la impresora**, no en la
máquina de build. `escpos-usb` usa `node-usb` (libusb). En Windows, libusb
**no puede abrir** una impresora con el driver estándar `usbprint.sys`. Si
no hacés este paso vas a ver:

```
LIBUSB_ERROR_NOT_SUPPORTED
LIBUSB_ERROR_ACCESS
Could not open device
```

Solución: reemplazar el driver de la impresora por **WinUSB** usando Zadig.

### Pasos

1. Descargá Zadig desde https://zadig.akeo.ie/ (free, portable).
2. Conectá la impresora USB y encendéla.
3. Abrí Zadig **como administrador**.
4. Menú: `Options` → `List All Devices`.
5. En el dropdown elegí tu impresora (ej. "POS-80", "TM-T20", "XP-58", etc.).
   Anotá el VID/PID que muestra arriba — los necesitás para
   `printers` de `config.yaml`.
6. En "Driver" del lado derecho seleccioná **WinUSB**.
7. Click en `Replace Driver`.
8. La impresora desaparece de "Dispositivos e impresoras" de Windows — eso es
   esperado.

### Cómo revertir

`Administrador de dispositivos` → click derecho en la impresora →
`Desinstalar dispositivo` → desconectá y reconectá. Windows reinstala
`usbprint.sys` automáticamente.

> No se puede tener WinUSB y usbprint a la vez en la misma impresora. Si
> imprimís desde otras apps vía spooler de Windows, esa función deja de
> funcionar mientras WinUSB esté activo.

---

## 3. Firewall: abrir puerto 4000 inbound

El agente escucha en `0.0.0.0:4000` (todas las interfaces) — ver
[agent/src/index.js:900](src/index.js#L900). Falta solo dejar pasar el
tráfico entrante en cada PC host:

```powershell
# PowerShell como administrador
New-NetFirewallRule -DisplayName "MangoPOS Agent 4000" -Direction Inbound `
  -Protocol TCP -LocalPort 4000 -Action Allow
```

Para borrar la regla más adelante:

```powershell
Remove-NetFirewallRule -DisplayName "MangoPOS Agent 4000"
```

---

## 4. Servicio Windows (lo registra el instalador)

El instalador Inno Setup registra el agente como servicio
`MangoPOSAgent` vía WinSW (`mangopos-agent-service.exe install/start`), con
inicio automático y reinicio en fallo (config en
[installer/windows/mangopos-agent-service.xml](../installer/windows/mangopos-agent-service.xml)).

### ⚠️ Caveat: WinUSB + servicio Windows

El servicio corre como `LocalSystem`. En algunos drivers WinUSB esa cuenta
no tiene acceso al device aunque sí lo tenga el usuario interactivo.
Síntomas: imprimir funciona si corrés el `.exe` a mano (doble click) pero
falla cuando lo levanta el servicio.

Si te pasa eso:

```cmd
sc config MangoPOSAgent obj= ".\<usuario>" password= "<password>"
sc stop MangoPOSAgent
sc start MangoPOSAgent
```

(Reemplazá `<usuario>` por la cuenta del usuario logueado en la PC host.)

---

## 5. Verificación end-to-end

### 5.1. IP LAN de la PC host

```cmd
ipconfig
```

Buscá `IPv4 Address` (algo como `192.168.1.50`, `10.0.0.x`, `172.20.x.x`).

### 5.2. Health check desde otra máquina del LAN

```bash
curl http://<ip-de-la-pc>:4000/health
```

Debe responder `{"status":"ok",...}`. Si no:

- ¿Misma red? (mismo router/SSID, no Wi-Fi de invitados aislado)
- Regla firewall: `Get-NetFirewallRule -DisplayName "MangoPOS Agent 4000"`
- Servicio corriendo: `sc query MangoPOSAgent`
- Logs: `C:\Program Files\MangoPOS\Agent\agent.log` y `mangopos-agent-service.out.log`

### 5.3. Test de impresión USB real desde otra PC

Reemplazá `<vid>` y `<pid>` por los hex de tu impresora (anotados de Zadig):

```bash
curl -X POST http://<ip-de-la-pc>:4000/print \
  -H "Content-Type: application/json" \
  -d '{
    "id": "TEST-1",
    "printer": { "type": "usb", "vid": "0x<vid>", "pid": "0x<pid>" },
    "content": { "type": "text", "title": "TEST LAN", "body": "Funciona!" }
  }'
```

Si imprime, el setup está correcto y la app Flutter va a poder imprimir igual
desde cualquier device del business.

### 5.4. Confirmar que la app Flutter ve el agente

La app publica automáticamente la URL del agente en
`device_agents.agent_url` reemplazando `localhost` por la IP LAN del host
(ver [printer_heartbeat_scheduler.dart:237](../lib/core/printing/printer_heartbeat_scheduler.dart#L237)).
Si una tablet no logra imprimir, revisá esa tabla en Supabase: el `agent_url`
debe ser `http://192.168.x.x:4000`, NO `http://127.0.0.1:4000`.

---

## Troubleshooting

| Síntoma | Causa probable | Fix |
|---|---|---|
| `LIBUSB_ERROR_NOT_SUPPORTED` al imprimir | Driver sigue siendo `usbprint.sys` | Aplicar Zadig → WinUSB (paso 2) |
| `No native build was found for platform=win32` | El `.exe` se compiló en Mac/Linux | Build en Windows (paso 1) |
| `curl /health` desde otra PC da timeout | Firewall o servicio caído | Revisar firewall y `sc query MangoPOSAgent` |
| Imprime con `.exe` manual pero no como servicio | `LocalSystem` no ve el USB con WinUSB | Cambiar cuenta del servicio (paso 4 caveat) |
| Tablet imprime al cloud pero no al host | `device_agents.agent_url` apunta a `127.0.0.1` | Reiniciar la app Flutter del host para que el heartbeat publique IP LAN |

---

## Otras plataformas (dev/test, no producción Windows)

```bash
npm run build:macos        # Intel
npm run build:macos-arm64  # Apple Silicon
npm run build:linux
npm run build:win-arm64
npm run build:all          # todos
```

Mismo principio: cada target debe construirse en (o con prebuilds para) la
plataforma destino para que los módulos nativos funcionen.

> En macOS/Linux **no** hace falta Zadig — libusb tiene acceso directo al
> USB sin reemplazar drivers (en Linux puede requerir reglas udev para no
> usar sudo).
