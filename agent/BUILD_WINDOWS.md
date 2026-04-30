# Build del agente para Windows

El módulo nativo `usb` (usado por `escpos-usb`) requiere binarios `.node`
específicos por plataforma. Si construyes el `.exe` en Mac/Linux, el binario
de Windows NO se incluye y al ejecutarlo en Windows obtienes:

```
No native build was found for platform=win32 arch=x64 runtime=node abi=108
    loaded from: C:\snapshot\agent\node_modules\usb
```

## Solución recomendada: build en Windows

Requiere Node.js 18 LTS instalado (https://nodejs.org).

```cmd
cd <ruta-del-agente>
rd /s /q node_modules
npm install
npm run build:exe
```

El binario queda en `dist\mangopos-agent.exe`. Reinstalá ese exe donde el
agente esté corriendo (reemplazá el ejecutable, reiniciá el servicio o el
proceso manual).

## Verificación post-build

1. En la PC, ejecutá el agente.
2. Desde otra máquina del mismo LAN:
   ```bash
   curl http://<ip-de-la-pc>:4000/health
   ```
   Debe responder `{"status":"ok",...}`.
3. Si el firewall bloquea, abrir puerto entrante 4000 (PowerShell admin):
   ```powershell
   New-NetFirewallRule -DisplayName "MangoPOS Agent 4000" -Direction Inbound `
     -Protocol TCP -LocalPort 4000 -Action Allow
   ```

## Alternativa cross-build desde Mac (no recomendado)

```bash
cd agent
npx prebuild-install -d node_modules/usb \
  --runtime=node --target=18.5.0 --arch=x64 --platform=win32
npm run build:exe
```

Solo funciona si la versión de `usb` instalada publica prebuilds para
win32-x64. Si falla, usá la opción de build en Windows.

## Otras plataformas

```bash
npm run build:macos        # Intel
npm run build:macos-arm64  # Apple Silicon
npm run build:linux
npm run build:win-arm64
npm run build:all          # todos
```

Mismo principio: cada target debe construirse en (o con prebuilds para) la
plataforma destino para que los módulos nativos funcionen.
