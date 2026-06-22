# Estado de la impresión Bluetooth por plataforma — MangoPOS

> Complemento operativo del PRD "Persistencia y Resiliencia de Conexión Bluetooth".
> Última actualización: 2026-06-21.

## Hecho de transporte (corrección al PRD)

El PRD asumía que las impresoras BT eran **Classic / RFCOMM** (socket SPP, UUID
`00001101-…`). **El código no usa RFCOMM en ningún lado.** La impresión BT en la
app móvil (Android/iOS) es **100% BLE / GATT** vía `flutter_blue_plus` /
`flutter_blue_plus_windows`:

- `lib/core/printing/bluetooth_print_service.dart` conecta por GATT y escribe a
  una characteristic; los service UUIDs que prioriza son puentes serie-sobre-BLE
  (ISSC SPP, HM-10, etc.).
- `lib/data/repositories/printing_service.dart` enruta BT como *"direct GATT"*.
- `grep -r 'BluetoothSocket|RFCOMM|00001101|flutter_bluetooth_serial' lib android`
  → sin resultados.
- Único Classic real: el **agente Node de Windows** habla SPP, pero por **puerto
  serie COM** (`escpos-serialport`), no sockets RFCOMM.

Implicación: la conclusión del PRD de que **iOS no puede** (Classic no-MFi) y por
tanto el iPad queda **WiFi-only** probablemente está **equivocada**: como el
transporte es BLE, iOS es viable vía Core Bluetooth (background `bluetooth-central`
+ state restoration). Queda pendiente de decidir/implementar.

## Estado por plataforma

| Plataforma | Transporte BT | Persistencia | Estado |
|---|---|---|---|
| **Android** | **Classic/RFCOMM** (nativo) **+** BLE (flutter_blue_plus), auto-elegido | **Sí** — enlace persistente + Foreground Service `connectedDevice` + reconexión con backoff + cola idempotente | **Implementado (Fase 1+2 + Classic)**. Falta verificación en hardware. |
| **iOS** | BLE (flutter_blue_plus) | **Tier A** — persistente en foreground + reconexión al volver (no hay FGS en iOS) | **Implementado (Tier A)**. Classic no aplica (iOS no lo expone). |
| **macOS** | BLE (flutter_blue_plus) | No (per-job `printRaw`) | Sin cambios. |
| **Windows** | Classic SPP vía COM (agente Node) **o** BLE (win_ble) | No | Sin cambios. Fase 4 del PRD (power-save del adaptador + reconexión + UI pairing) pendiente. |

## Lo implementado

### Núcleo (transporte-agnóstico)

- **Conexión persistente:** `BlePrinterConnectionManager` mantiene el enlace vivo
  entre tickets (en vez de connect→write→disconnect por job). Opera sobre
  `PrinterLink`, con dos backends auto-elegidos: `ClassicLink` (RFCOMM) si el
  equipo expone SPP, `BleLink` (GATT) si no.
- **Reconexión resiliente:** detección de caída por eventos del enlace + heartbeat
  pasivo; backoff exponencial 0.5s→30s con jitter.
- **Cola sin pérdida:** `BlePrintJobQueue` (FIFO, idempotente por `jobId`,
  persistida en JSON) encola durante la desconexión y vacía en orden al
  reconectar. Misma idempotency key que el cloud fallback.
- **Activación:** `printer_heartbeat_scheduler.dart` sincroniza el set de
  impresoras BT activas en cada tick (arranca al login, derriba al logout sin
  borrar la cola).
- **Observabilidad:** badge en el header del shell (azul = conectado, amarillo =
  reconectando, oculto si no hay BT).

### Android

- **Proceso vivo en background:** `PrinterForegroundService.kt` (tipo
  `connectedDevice`) + channel `mangopos/printer_fgs`. No posee el socket: solo
  conserva el proceso priorizado y la notificación discreta.
- **Transporte Classic/RFCOMM:** `ClassicBtPlugin.kt` + channel `mangopos/classic_bt`
  (socket SPP, `bondedDevices`, write/disconnect, eventos de estado). Streamea el
  ticket completo (sin trocear por MTU) → más rápido que BLE; única vía para
  impresoras Classic-only.
- **Diagnóstico (Fase 0 in-app):** Ajustes › Impresoras › 🔵 → lista las
  impresoras pareadas con veredicto **Classic/SPP** vs **BLE-only**
  (`BluetoothDiagnosticsScreen`).

### iOS (Tier A)

- Persistencia en foreground + **reconexión al volver a foreground**
  (`didChangeAppLifecycleState`). iOS no permite sostener el enlace con la app en
  background (límite de plataforma, igual que Loyverse); cubre el uso real del POS
  (foreground toda la jornada). Classic no aplica en iOS.

## Pendiente

- **Verificación en hardware** (Android e iOS): pantalla apagada / background;
  apagar/encender la impresora con jobs en cola (deben salir una sola vez, en
  orden); confirmar Classic vs BLE por modelo con el diagnóstico in-app.
- **Compilar el lado Kotlin en dispositivo** (el análisis Dart no cubre el nativo:
  `PrinterForegroundService.kt`, `ClassicBtPlugin.kt`, `MainActivity.kt`).
- **Fase 0**: correr la auditoría (`PRD_BLUETOOTH_FASE0_AUDITORIA.md`) para
  registrar el transporte por modelo.
- **Fase 4** (agente Windows): power-save del adaptador + reconexión + UI pairing.
