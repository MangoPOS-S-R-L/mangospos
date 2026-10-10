# Recuperación automática de IP de impresoras

La impresora de red se identifica por su MAC guardada. Antes de enviar bytes,
el agente verifica que la IP actual tenga esa MAC y acepte el puerto configurado.
La IP anterior y la caché son pistas que se vuelven a comprobar; una IP que ahora
pertenezca a otra impresora se descarta. Si la IP cambió por DHCP, el agente busca
la MAC en ARP y en las redes candidatas y usa la dirección verificada.
Si los candidatos conocidos o los probes del escaneo en curso encuentran más
de una IP verificada con la misma MAC, detiene la resolución por ambigüedad.

## API de producción

`agent/src/index.js` inicia el servidor de `src/http/server.js` en el puerto
4000. Las rutas usan el mismo control de autorización del resto de la API
(JWT cuando `JWT_SECRET` está configurado). El servidor antiguo de
`src/main.js` → `src/api/server.js` también tiene estas rutas y conserva su
autenticación por token de configuración.

| Ruta POST | Cuerpo | Respuesta válida |
| --- | --- | --- |
| `/api/printers/mac-for-ip` | `{ "ip": "192.168.1.80", "port": 9100 }` | `{ "ip": "192.168.1.80", "port": 9100, "mac": "aa:bb:cc:dd:ee:02", "verified": true }` |
| `/api/printers/resolve-by-mac` | `{ "mac": "aa:bb:cc:dd:ee:02", "printerId": "id-guardado", "ip": "192.168.1.80", "port": 9100, "skipCache": true }` | `{ "ip": "192.168.1.81", "port": 9100, "mac": "aa:bb:cc:dd:ee:02", "verified": true, "source": "scan" }` |
| `/api/printers/invalidate-mac-cache` | `{ "mac": "aa:bb:cc:dd:ee:02" }` | `{ "ok": true, "mac": "aa:bb:cc:dd:ee:02" }` |

La resolución responde 400 para identidad/IP/puerto inválidos y 404 si no puede
verificar la impresora. `port` vale 9100 cuando se omite. `ip` y `printerId`
son opcionales para resolver por MAC. `skipCache` descarta la pista en memoria;
incluso sin ese parámetro el agente verifica la IP almacenada antes de usarla.

La impresión directa en `/api/printers/raw` acepta `dataBase64` o `dataHex` y
`printer: { id, type: "network", ip, port, mac }`, junto con `printerId` estable.
También admite los campos `ip`, `port` y `mac` en el cuerpo para clientes antiguos.
La respuesta exitosa incluye la IP, el puerto y la MAC verificados. Los jobs de
`/print` y de la cola cloud usan la misma verificación antes de escribir. Los
payloads RAW completos se envían sin añadir comandos ni cortes.

La app guarda la IP recuperada en su configuración; el agente actualiza la
configuración en memoria de la cola antigua, sin reescribir `config.yaml`.

## Reintentos y entrega incierta

Un fallo antes de empezar a escribir puede invalidar la caché, resolver de nuevo
la MAC y hacer un único reintento. Un error o timeout después de iniciar la
escritura responde `deliveryUncertain: true` y `safeToRetry: false`. La cola
registra el prefijo `[DELIVERY_UNCERTAIN]` para impedir el reenvío automático
o el envío a una impresora de respaldo. Antes de reimprimir manualmente, revise
si el ticket ya salió.

Al reiniciar el agente, los jobs SQLite que quedaron en `printing` pasan a
`failed` con ese mismo prefijo; los jobs que estaban en `queued` se conservan.
La migración `20261009_0001_printer_delivery_uncertain.sql` aplica el estado
terminal equivalente a errores y claims cloud vencidos. El worker cloud renueva
cada 20 s los claims de los tickets que tiene en memoria (imprimiéndose o
esperando turno), así que solo vence el claim de un agente que dejó de
renovarlo: se cayó o lleva más de 60 s sin internet.

Orden de despliegue: primero actualizar el agente en todos los equipos, después
aplicar la migración. Un agente viejo, sin renovación, con la migración ya
aplicada dejaría como terminales los tickets que esperan más de 60 s detrás de
una impresora lenta: comandas que nunca salen. El agente nuevo con la base vieja
se comporta como hoy: la renovación solo registra un aviso, y un fallo incierto
todavía puede reintentarse.

## Alcance de red y plataforma

- La MAC se obtiene de ARP en Windows/macOS o de `ip neigh`/ARP en Linux. El
  agente necesita acceso a esos comandos y a la misma red de capa 2 de la
  impresora. Una VLAN enrutada puede ser alcanzable por TCP sin exponer su MAC;
  el agente detiene la impresión con identidad guardada si no puede verificarla.
- El escaneo usa las interfaces IPv4 y `discovery.subnets`, con CIDRs de `/22`
  a `/32`, hasta 24 probes concurrentes. Interfaces más grandes usan un `/24`
  acotado. La resolución tiene un presupuesto aproximado de 12 segundos; una
  búsqueda sin resultado puede requerir un intento posterior.
- Una impresora configurada sin MAC conserva la impresión por IP explícita;
  necesita guardar una MAC verificada para disponer de recuperación automática.
- La app nativa también recupera sin agente de escritorio: ARP/SNMP en Android,
  macOS, Windows y Linux; SNMP en iOS. El barrido nativo cubre hasta cuatro `/24`
  privadas conectadas, con un presupuesto total de 12 segundos. Una red mayor
  puede requerir los CIDRs configurados en el agente. El navegador usa el agente.
- iOS requiere acceso de red local y SNMP habilitado en la impresora. No puede
  leer la tabla ARP del sistema. Una MAC conocida puede identificarse entre
  varias interfaces SNMP; una captura inicial ambigua se rechaza.
- Las pruebas del código no sustituyen una prueba controlada en el equipo y la
  red de destino.

## Integración de la aplicación y base de datos

Facturas, comandas, muestras y heartbeat usan la misma comprobación de IP/MAC.
Las búsquedas simultáneas de una impresora se unen. Un escaneo fallido tiene
30 segundos de espera antes del siguiente barrido. El heartbeat se ejecuta
cada 30 segundos y respeta el negocio activo.

La dirección verificada queda en memoria y en preferencias locales antes del
guardado remoto. Se comprueba nuevamente al usarla, incluso después de reiniciar.
Una caída de internet permite imprimir por esa dirección; el siguiente heartbeat
reintenta guardar en Supabase. Se mezclan `ip_address`/`mac` y los campos de
`connection_config` sin borrar ajustes de impresión. Un cambio manual de
MAC/IP/puerto invalida la recuperación que estuviera pendiente.

Las tarjetas y el diálogo de configuración reciben los cambios de dirección.
Los campos editados por el usuario se conservan. El agente móvil ofrece captura
y resolución por MAC y `/check-connectivity`; exige una impresora activa autorizada, MAC y puerto guardados,
y conserva su último snapshot autorizado durante una caída de internet.

Aplicar `supabase/migrations/20261009_0001_printer_delivery_uncertain.sql`
después de actualizar el agente en todos los equipos (ver el orden de despliegue
arriba). Evita reintentos automáticos y failover de tickets con
`[DELIVERY_UNCERTAIN]` y de claims abandonados durante una caída del agente. Los trabajos pendientes y los fallos previos a escribir conservan sus
reintentos. Revisar si salió el ticket antes de solicitar una reimpresión manual.
El rollback manual restaura la política anterior. La migración fue validada en
PostgreSQL local y no se aplicó a una base remota desde esta implementación.

## Pruebas de código

Desde `agent/` ejecute `npm run test:printer-recovery`. La suite usa I/O
inyectado, sockets simulados y SQLite en memoria. No envía datos a impresoras
ni abre un servidor HTTP real. Cubre DHCP, IP reasignada, caché obsoleta,
puertos personalizados, rutas de producción, jobs RAW y entrega incierta.

## Build y reinstalación oficial de Windows

Las fuentes de `agent/src/` y del paquete antiguo `agent/MangoPOS-Agent/src/`
incluyen la recuperación. El flujo oficial usa **`agent/`**, con Node 20 y
`@yao-pkg/pkg`; el paquete antiguo conserva Node 18/`pkg` y no debe usarse como
fuente del instalador oficial. Editar fuentes no actualiza los binarios ya
generados ni el agente instalado.

En una máquina Windows x64, con Node 20, Flutter e Inno Setup 6 disponibles:

```powershell
Set-Location agent
npm ci
npm run test:printer-recovery
Set-Location ..
powershell -ExecutionPolicy Bypass -File .\installer\windows\build_inno.ps1
```

El script compila la app y `agent/dist/mangopos-agent.exe`, prepara
`build/installer_stage/{App,Agent,Support}` y genera
`build/installer/MangoPOS-Setup-<version>-x64.exe`. El stage del agente incluye
`better_sqlite3.node` de Windows x64, configuración y WinSW. Los módulos
nativos deben corresponder al runtime y plataforma del binario empaquetado.
Para integrar cambios del agente, no use `-SkipAgentBuild` ni `-SkipStage`.

Ejecutar ese instalador en el host actualiza `{app}/Agent/mangopos-agent.exe`
y reemplaza el servicio `MangoPOSAgent`; ese paso detiene y vuelve a iniciar
el agente y debe programarse cuando no haya tickets imprimiéndose. La app
encuentra el agente en la carpeta `Agent` junto a `App` en Windows/Linux y en
`Contents/Resources/Agent` en macOS. En desarrollo usa `node agent/src/index.js`.

En esta implementación se modificaron únicamente fuentes y pruebas. Los
ejecutables existentes, el instalador distribuido y los servicios en producción
no se reconstruyeron, publicaron ni reiniciaron.
