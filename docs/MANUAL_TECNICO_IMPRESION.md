# Manual Técnico — Sistema de Impresión MangoPOS v2

> **Audiencia:** Desarrolladores, equipo de soporte técnico, integradores.
> **Documentos relacionados:** [PRD_IMPRESION_TOAST_LEVEL.md](PRD_IMPRESION_TOAST_LEVEL.md), [GUIA_USUARIO_IMPRESION.md](GUIA_USUARIO_IMPRESION.md).

---

## 1. Arquitectura general

```
┌──────────────────────────────────────────────────────────────┐
│ App Flutter (lib/)                                           │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ Presentation                                           │  │
│  │  • table_order_screen.dart (botón Pre-cuenta)         │  │
│  │  • pre_check_dialog.dart                              │  │
│  │  • print_destination_picker.dart  ← NUEVO             │  │
│  │  • printing_health_view.dart                          │  │
│  └────────────────────────┬───────────────────────────────┘  │
│                           │                                  │
│  ┌────────────────────────▼───────────────────────────────┐  │
│  │ Services                                               │  │
│  │  • PrintOrchestrator      ← NUEVO                      │  │
│  │  • PrintTicketBuilder     (existe, refactor)          │  │
│  │  • PrintJobDispatcher     ← NUEVO                      │  │
│  └────────────────────────┬───────────────────────────────┘  │
│                           │                                  │
│  ┌────────────────────────▼───────────────────────────────┐  │
│  │ Data                                                   │  │
│  │  • PrintingRepository (refactor)                      │  │
│  │  • PrepStationRepository  ← NUEVO                     │  │
│  │  • DevicePrinterBindingRepository  ← NUEVO            │  │
│  │  • PrinterHealthRepository  ← NUEVO                   │  │
│  └────────────────────────┬───────────────────────────────┘  │
└───────────────────────────┼──────────────────────────────────┘
                            │
                            │ (HTTP, Realtime)
                            │
┌───────────────────────────▼──────────────────────────────────┐
│ Supabase                                                     │
│  • print_jobs (queue)                                        │
│  • printers, prep_stations, prep_station_printers           │
│  • device_printer_bindings, device_agents_health            │
│  • printer_health                                            │
│  • RPC: fn_enqueue_print_job, fn_retry_failed_jobs          │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            │ (polling / realtime)
                            │
┌───────────────────────────▼──────────────────────────────────┐
│ Local Agent (agent/)                                         │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ Job Worker (polls print_jobs)                          │  │
│  └────────────────────────┬───────────────────────────────┘  │
│                           │                                  │
│  ┌────────────────────────▼───────────────────────────────┐  │
│  │ Transports (plugin)                                    │  │
│  │  • LanTransport       (TCP socket 9100)                │  │
│  │  • UsbTransport       (libusb / escpos-usb)            │  │
│  │  • BluetoothTransport (SPP socket)                     │  │
│  │  • SerialTransport    (COM / /dev/tty)                 │  │
│  │  • CupsTransport      (lpr / cups CLI)                 │  │
│  └────────────────────────┬───────────────────────────────┘  │
│                           │                                  │
│  ┌────────────────────────▼───────────────────────────────┐  │
│  │ ESC/POS Encoder + Discovery + Health Probe             │  │
│  └────────────────────────────────────────────────────────┘  │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
                     [IMPRESORAS FÍSICAS]
```

---

## 2. Modelo de datos

### 2.1 Tablas

#### `printers` (extendida)

| Columna | Tipo | Notas |
|---|---|---|
| `id` | uuid PK | |
| `business_id` | uuid FK | |
| `branch_id` | uuid FK NULL | |
| `name` | text | "Cocina Caliente" |
| `transport` | text | `lan` / `usb` / `bluetooth` / `serial` / `cups` |
| `purpose` | text | `receipt` / `precheck` / `kitchen` / `label` / `general` |
| `connection_config` | jsonb | depende del transport (ver §2.2) |
| `codepage` | text | default `CP858` |
| `paper_width_mm` | int | default 80 |
| `is_active` | boolean | |
| `last_seen_at` | timestamptz | última vez que respondió a health probe |
| `last_error` | text | último error registrado |
| `prints_orders` | boolean | LEGACY, se mantiene por compatibilidad |
| `prints_prebills` | boolean | LEGACY |
| `prints_receipts` | boolean | LEGACY |

> **Nota legacy:** los flags booleanos se mantienen un tiempo durante la migración. La nueva lógica usa `purpose` + `prep_station_printers`. Después de Fase 6, deprecar los flags.

#### `prep_stations`

| Columna | Tipo | Notas |
|---|---|---|
| `id` | uuid PK | |
| `business_id` | uuid FK | |
| `branch_id` | uuid FK NULL | NULL = aplica a todas las sucursales |
| `name` | text | "Cocina Caliente" |
| `color` | text | hex para UI |
| `display_order` | int | |
| `is_active` | boolean | |

#### `prep_station_printers`

| Columna | Tipo | Notas |
|---|---|---|
| `prep_station_id` | uuid FK | PK compuesto |
| `printer_id` | uuid FK | PK compuesto |
| `priority` | int | 1 = principal, 2+ = fallback |

#### `product_prep_stations`

N:M productos ↔ estaciones.

#### `device_printer_bindings`

| Columna | Tipo | Notas |
|---|---|---|
| `device_id` | text | PK compuesto, viene de [device_identity.dart](../lib/core/printing/device_identity.dart) |
| `printer_id` | uuid FK | PK compuesto |
| `is_local_owner` | boolean | el device "es dueño" de la impresora física |
| `paired_at` | timestamptz | |

#### `device_agents_health`

Heartbeat de cada agent. Refresca cada 30s.

| Columna | Tipo | Notas |
|---|---|---|
| `device_id` | text PK | |
| `business_id` | uuid FK | |
| `last_heartbeat` | timestamptz | |
| `agent_version` | text | |
| `os` | text | |
| `available_transports` | text[] | `{lan,usb,bluetooth}` |
| `metadata` | jsonb | |

#### `printer_health`

Estado actual de cada impresora.

| Columna | Tipo | Notas |
|---|---|---|
| `printer_id` | uuid PK | |
| `status` | text | `online` / `offline` / `low_paper` / `no_paper` / `cover_open` / `error` / `unknown` |
| `last_checked_at` | timestamptz | |
| `consecutive_failures` | int | |
| `details` | jsonb | mensaje, código de error, etc. |

#### `print_jobs` (extendida)

| Columna | Tipo | Notas |
|---|---|---|
| `id` | uuid PK | |
| `business_id` | uuid FK | |
| `printer_id` | uuid FK | |
| `target_device_id` | text NULL | si NULL → cualquier device que pueda imprimirla |
| `transport` | text | snapshot del transport al momento de encolar |
| `payload` | bytea | ESC/POS bytes ya generados |
| `status` | text | `pending` / `in_progress` / `printed` / `failed` / `dead` / `retry` |
| `attempts` | int | |
| `max_attempts` | int | default 5 |
| `next_attempt_at` | timestamptz | para backoff |
| `error_log` | jsonb | array de `{at, message, transport}` |
| `idempotency_key` | uuid | dedupe en client retries |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |
| `printed_at` | timestamptz | |

### 2.2 Esquemas de `connection_config`

**LAN:**
```json
{
  "ip": "192.168.1.60",
  "port": 9100,
  "timeout_ms": 3000
}
```

**USB:**
```json
{
  "vendor_id": "04b8",
  "product_id": "0e15",
  "interface": 0,
  "endpoint_out": "0x01"
}
```

**Bluetooth (SPP classic):**
```json
{
  "mac": "00:11:22:33:44:55",
  "pin": "0000",
  "profile": "spp",
  "channel": 1
}
```

**Serial:**
```json
{
  "port": "COM3",
  "baud": 9600,
  "parity": "none",
  "data_bits": 8,
  "stop_bits": 1
}
```

**CUPS:**
```json
{
  "queue_name": "Epson_TM_T20III",
  "options": {"media": "Custom.80x297mm"}
}
```

### 2.3 RPCs

```sql
-- Encolar un print job (con idempotencia)
create or replace function fn_enqueue_print_job(
  p_printer_id uuid,
  p_payload bytea,
  p_idempotency_key uuid default gen_random_uuid(),
  p_target_device_id text default null
) returns uuid ...

-- Marcar job como impreso
create or replace function fn_mark_job_printed(
  p_job_id uuid
) returns void ...

-- Marcar job como fallido (incrementa attempts, programa retry)
create or replace function fn_mark_job_failed(
  p_job_id uuid,
  p_error text,
  p_transport text
) returns void ...

-- Re-encolar jobs muertos
create or replace function fn_retry_dead_jobs(
  p_business_id uuid
) returns int ...
```

---

## 3. Capas de la app Flutter

### 3.1 PrintOrchestrator (NUEVO)

`lib/services/printing/print_orchestrator.dart`

Responsabilidades:
- Recibe una orden de "imprimir X en destino Y".
- Resuelve la(s) impresora(s) destino según `prep_stations` y `purpose`.
- Decide si imprime directo (mismo device, LAN) o encola para otro device (BT/USB binding).
- Maneja fallback automático si la primary falla.

API:

```dart
class PrintOrchestrator {
  Future<PrintResult> print({
    required PrintRequest request,
    PrinterConfig? forcedPrinter,  // bypass de selector
  });

  Future<List<PrinterConfig>> getAvailableDestinations({
    required String businessId,
    required PrinterPurpose purpose,
  });

  Future<void> sendOrderToKitchen({
    required Order order,
    required String businessId,
  });
}

class PrintRequest {
  final String type;             // 'precheck' / 'invoice' / 'order'
  final Map<String, dynamic> data;
  final String purpose;          // matches PrinterConfig.purpose
  final String? targetStationId; // para comandas: estación específica
}
```

### 3.2 PrintJobDispatcher (NUEVO)

`lib/services/printing/print_job_dispatcher.dart`

Encolar y supervisar jobs. Stream de estado para UI.

```dart
class PrintJobDispatcher {
  Future<String> enqueue(PrintRequest req, PrinterConfig printer);
  Stream<PrintJobStatus> watch(String jobId);
  Future<void> cancel(String jobId);
  Future<List<PrintJob>> getRecentJobs(int limit);
}
```

### 3.3 Print Destination Picker (NUEVO UI)

`lib/presentation/sales/widgets/print_destination_picker.dart`

Bottom sheet que muestra:
- Lista de impresoras disponibles para el purpose pedido.
- Estado de cada una (verde/amarillo/rojo).
- Última impresora usada en este device (recordada en SharedPreferences).
- Opciones especiales (pantalla, WhatsApp si configurado).

```dart
Future<PrintDestination?> showPrintDestinationPicker(
  BuildContext context, {
  required List<PrinterConfig> printers,
  required PrinterPurpose purpose,
  List<SpecialDestination> specialDestinations = const [],
});
```

### 3.4 Refactor de `_handlePrintFlow`

Hoy en [table_order_screen.dart:3325](../lib/presentation/sales/view/table_order_screen.dart#L3325) se elige impresora automáticamente. Cambio:

```dart
Future<void> _handlePrintFlow(...) async {
  final orchestrator = ref.read(printOrchestratorProvider);
  final destinations = await orchestrator.getAvailableDestinations(
    businessId: businessId,
    purpose: type == 'precheck' ? PrinterPurpose.precheck : PrinterPurpose.receipt,
  );

  PrinterConfig? selected;
  if (destinations.length == 1) {
    selected = destinations.first;
  } else if (destinations.length > 1) {
    final result = await showPrintDestinationPicker(context, ...);
    if (result == null) return; // cancelado
    selected = result.printer;
  }

  await orchestrator.print(
    request: PrintRequest(type: type, data: data, purpose: ...),
    forcedPrinter: selected,
  );
}
```

---

## 4. Agent local

### 4.1 Estructura del agent

```
agent/
├── package.json
├── src/
│   ├── index.ts            # entry point, heartbeat
│   ├── job_worker.ts       # polls print_jobs
│   ├── transports/
│   │   ├── base.ts         # interface
│   │   ├── lan.ts
│   │   ├── usb.ts
│   │   ├── bluetooth.ts
│   │   ├── serial.ts
│   │   └── cups.ts
│   ├── discovery/
│   │   ├── mdns.ts         # descubrir LAN
│   │   ├── usb_devices.ts
│   │   └── bt_devices.ts
│   ├── health_probe.ts     # ping a impresoras
│   ├── local_queue.ts      # SQLite local
│   └── supabase_client.ts
├── escpos/
│   ├── encoder.ts
│   └── commands.ts
└── README.md
```

### 4.2 Loop principal

```typescript
async function main() {
  await registerAgent();
  setInterval(sendHeartbeat, 30_000);
  setInterval(probePrintersHealth, 60_000);

  while (true) {
    const jobs = await fetchPendingJobs(myDeviceId);
    await Promise.all(jobs.map(processJob));
    await sleep(500);
  }
}

async function processJob(job: PrintJob) {
  const printer = await getPrinterConfig(job.printer_id);
  const transport = getTransport(printer.transport);

  try {
    await markInProgress(job.id);
    await transport.sendRaw(job.payload, printer);
    await markPrinted(job.id);
  } catch (err) {
    await markFailed(job.id, err.message, printer.transport);
    if (job.attempts + 1 >= job.max_attempts) {
      await notifyDeadJob(job);
    } else {
      // Reintentar con backoff
      await scheduleRetry(job.id, computeBackoff(job.attempts));
    }
  }
}
```

### 4.3 Implementación de cada transport

#### LAN
```typescript
class LanTransport implements Transport {
  async sendRaw(payload: Buffer, p: PrinterConfig) {
    const { ip, port = 9100, timeout_ms = 3000 } = p.connection_config;
    const socket = net.createConnection({ host: ip, port, timeout: timeout_ms });
    await new Promise((resolve, reject) => {
      socket.on('connect', () => {
        socket.write(payload, (err) => err ? reject(err) : resolve(null));
        socket.end();
      });
      socket.on('error', reject);
      socket.on('timeout', () => reject(new Error('TIMEOUT')));
    });
  }

  async probeHealth(p: PrinterConfig): Promise<PrinterHealth> {
    // Enviar DLE EOT 1 → respuesta status real-time
    // Parsear bits para detectar offline, sin papel, tapa abierta, etc.
  }
}
```

#### USB
```typescript
class UsbTransport implements Transport {
  async sendRaw(payload: Buffer, p: PrinterConfig) {
    const { vendor_id, product_id } = p.connection_config;
    const device = usb.findByIds(parseInt(vendor_id, 16), parseInt(product_id, 16));
    device.open();
    const iface = device.interface(p.connection_config.interface ?? 0);
    iface.claim();
    const endpoint = iface.endpoints[0]; // OUT
    await new Promise((resolve, reject) => {
      endpoint.transfer(payload, (err) => err ? reject(err) : resolve(null));
    });
    iface.release(true, () => device.close());
  }
}
```

#### Bluetooth (Classic SPP)
```typescript
class BluetoothTransport implements Transport {
  async sendRaw(payload: Buffer, p: PrinterConfig) {
    const { mac, channel = 1 } = p.connection_config;
    const btSerial = new BluetoothSerial();
    await btSerial.connect(mac, channel);
    await btSerial.write(payload);
    btSerial.close();
  }
}
```

### 4.4 Health probe

Cada 60s, para cada impresora:
1. Intentar abrir conexión (LAN: TCP connect, BT: SPP, USB: device.open).
2. Enviar `DLE EOT 1` (real-time status) si es ESC/POS.
3. Parsear respuesta:
   - Bit 2 = drawer open
   - Bit 3 = printer offline
   - Bit 5 = cover open
   - Bit 6 = paper feed pressed
4. Actualizar `printer_health.status`.
5. Si falla N veces seguidas → `status='offline'` y notificar.

---

## 5. Flujos detallados

### 5.1 Imprimir pre-cuenta

```
[Usuario presiona Pre-cuenta en table_order_screen]
              │
              ▼
[orchestrator.getAvailableDestinations(purpose=precheck)]
              │
              ▼
       ¿Cuántas hay?
        ┌─────┴─────┐
        ▼           ▼
       1+         >1
        │           │
        ▼           ▼
   [imprime    [showPrintDestinationPicker]
    directo]         │
                     ▼
               [Usuario elige]
                     │
                     ▼
        [orchestrator.print(forcedPrinter)]
                     │
                     ▼
        ¿Transport del device actual o ajeno?
              ┌───────┴────────┐
              ▼                ▼
         [Direct        [Encola en print_jobs
          send LAN]      con target_device_id]
              │                │
              ▼                ▼
        [Impresora]      [Agent del otro
                          device la procesa]
```

### 5.2 Enviar comanda a cocina

```
[Mesero envía orden con 5 items]
              │
              ▼
[orchestrator.sendOrderToKitchen(order)]
              │
              ▼
[Para cada item: lookup product_prep_stations]
              │
              ▼
[Agrupar por prep_station]
   • Cocina Caliente: 2 items
   • Bar: 2 items
   • Postres: 1 item
              │
              ▼
[Para cada estación: getStationPrinters(ordered by priority)]
              │
              ▼
[Construir ticket ESC/POS por estación]
              │
              ▼
[Encolar print_job por cada (estación, primary printer)]
              │
              ▼
[Agent procesa: si primary falla, intenta priority 2]
              │
              ▼
[Si todos fallan: notificación push + audio fallback]
```

### 5.3 Re-print desde historial

```
[Usuario va a historial de tickets]
              │
              ▼
[Selecciona ticket → "Reimprimir"]
              │
              ▼
[Selector de impresora (con destino original pre-seleccionado)]
              │
              ▼
[Nuevo print_job con flag `is_reprint = true`]
```

---

## 6. Códigos ESC/POS de referencia

### Inicialización y configuración
```
ESC @          → reset (1B 40)
ESC t n        → codepage (1B 74 n)
  n=0  CP437
  n=16 CP1252 (Windows Latin)
  n=19 CP858 (con €, ñ)
GS L nL nH     → left margin
GS W nL nH     → print area width
```

### Texto
```
ESC E n        → bold on (n=1) / off (n=0)
ESC a n        → alineación (0=left, 1=center, 2=right)
GS ! n         → tamaño (n=00 normal, 11 doble, 22 cuádruple)
ESC d n        → feed n líneas
```

### Corte
```
ESC i          → corte total (algunas)
GS V 0         → corte total
GS V 1         → corte parcial
GS V m n       → corte con feed (m=66, n=píxeles)
```

### Cajón
```
ESC p m t1 t2  → abrir gaveta (m=0 pin2 / 1 pin5)
```

### Status (real-time)
```
DLE EOT n      → estado n
  n=1 printer status
  n=2 offline status
  n=3 error status
  n=4 paper status
```

### Tabla de quirks por marca (en evolución)

| Marca | Quirk | Workaround |
|---|---|---|
| Epson TM-T20 | Codepage default CP437 | enviar `ESC t 19` |
| Xprinter genérico | A veces no responde DLE EOT | health probe por TCP connect solo |
| Digton DT-200B | Acentos en CP850 | `ESC t 4` para CP858 |
| Bixolon | Corte requiere `GS V m n` específico | usar `GS V 66 16` |
| Star TSP | No usa ESC/POS estándar | wrapper específico StarPRNT |
| Cherry/Tysso | BT classic con PIN 1234 (no 0000) | doc específica |

---

## 7. Extender el sistema

### 7.1 Agregar un nuevo transport

1. Crear `agent/src/transports/mi_transport.ts`:
```typescript
export class MiTransport implements Transport {
  async sendRaw(payload: Buffer, p: PrinterConfig) { ... }
  async probeHealth(p: PrinterConfig): Promise<PrinterHealth> { ... }
  async discover(): Promise<DiscoveredPrinter[]> { ... }
}
```

2. Registrar en factory:
```typescript
// agent/src/transports/factory.ts
case 'mi_transport': return new MiTransport();
```

3. Agregar a CHECK constraint:
```sql
alter table public.printers
  drop constraint printers_transport_check,
  add constraint printers_transport_check
    check (transport in ('lan','usb','bluetooth','serial','cups','mi_transport'));
```

4. UI: agregar opción en el selector de tipo en `printers_view.dart`.

### 7.2 Agregar un nuevo destino especial (no impresora)

Ej. enviar pre-cuenta por Telegram:

1. En `PrintDestination`, agregar `DestinationType.telegram`.
2. En el bottom sheet, agregar opción.
3. Implementar handler en `PrintOrchestrator.print`:
```dart
if (destination.type == DestinationType.telegram) {
  await _telegramService.sendPdf(...);
  return;
}
```

### 7.3 Agregar un nuevo purpose

Ej. impresora de "kitchen-bar-combo" (mezcla):

1. Agregar a CHECK constraint.
2. Agregar enum en Dart.
3. Lógica de filtrado en `getAvailableDestinations`.

---

## 8. Debugging

### 8.1 Verificar que una impresora LAN responde

```bash
# Desde una PC de la red
ping 192.168.1.60
nc -vz 192.168.1.60 9100
echo "Hola mundo" | nc 192.168.1.60 9100
```

### 8.2 Verificar logs del agent

```bash
# macOS
tail -f ~/Library/Logs/mangospos-agent/agent.log

# Windows
type %APPDATA%\MangosPOS\agent\logs\agent.log

# Linux
journalctl -u mangospos-agent -f
```

### 8.3 Ver jobs en cola

```sql
select id, printer_id, status, attempts, last_error, created_at
from public.print_jobs
where business_id = '...'
order by created_at desc
limit 50;
```

### 8.4 Ver salud de impresoras

```sql
select p.name, ph.status, ph.consecutive_failures, ph.last_checked_at, p.last_error
from public.printers p
left join public.printer_health ph on ph.printer_id = p.id
where p.business_id = '...';
```

### 8.5 Re-encolar todos los jobs fallidos

```sql
update public.print_jobs
set status = 'pending', next_attempt_at = now(), attempts = 0
where status in ('failed', 'dead') and business_id = '...';
```

### 8.6 Forzar health probe

```sql
select fn_force_probe_printer('printer-uuid-aqui');
```

### 8.7 Activar logs verbosos en el agent

```bash
LOG_LEVEL=debug npm start
# o variable env permanente
echo 'LOG_LEVEL=debug' >> ~/.mangospos-agent/.env
```

### 8.8 Test de impresión desde Dart REPL

```dart
final printer = await ref.read(printingPrintersRepositoryProvider)
  .getPrinter('printer-uuid');
await ref.read(printOrchestratorProvider).print(
  request: PrintRequest(
    type: 'test',
    data: {'text': 'PRUEBA'},
    purpose: 'general',
  ),
  forcedPrinter: printer,
);
```

---

## 9. Tests

### 9.1 Tests unitarios obligatorios

- `PrepStationRepository`: CRUD, ordering, filtrado por business/branch.
- `PrintOrchestrator`: resolución de destinos, fallback.
- `PrintJobDispatcher`: enqueue idempotente, status updates.
- Transports: mock de socket / USB / BT.

### 9.2 Tests de integración

- Encolar 100 jobs y verificar que el agent los procesa.
- Apagar impresora simulada y verificar fallback.
- Simular `agent` desconectado: jobs quedan en pending.

### 9.3 Tests E2E (manual)

Matrix de configuraciones:
- Solo LAN, 1 impresora.
- Solo LAN, 4 impresoras + estaciones.
- LAN + BT mixto.
- LAN + USB mixto.
- Multi-device: comanda desde device A imprime en BT del device B.

---

## 10. Compatibilidad y migración

### 10.1 Modo legacy

Mientras está la migración (Fase 1 → Fase 6), conviven los dos modelos:

- `printers.prints_prebills` / `prints_orders` / `prints_receipts` siguen funcionando para clientes que no hayan migrado.
- Si `purpose` está definido → tiene prioridad.
- Si `prep_station_printers` existe → tiene prioridad sobre `printer_areas`.

### 10.2 Script de backfill

Pseudocódigo (a implementar en migración):

```sql
-- Asignar purpose desde flags legacy
update public.printers
set purpose = case
  when prints_receipts = true then 'receipt'
  when prints_prebills = true then 'precheck'
  when prints_orders = true then 'kitchen'
  else 'general'
end
where purpose = 'general';

-- Asumir LAN para todo lo existente
update public.printers
set transport = 'lan'
where transport = 'lan' and connection_config = '{}'::jsonb;

-- Migrar IP/port a connection_config
update public.printers
set connection_config = jsonb_build_object(
  'ip', ip_address,
  'port', coalesce(port, 9100)
)
where connection_config = '{}'::jsonb and ip_address is not null;
```

### 10.3 Deprecation timeline

- v2.0: nuevos campos disponibles, viejos siguen funcionando.
- v2.1: warning en logs cuando se usa el modelo viejo.
- v2.2: viejos campos read-only.
- v3.0: drop columns legacy.

---

## 11. Seguridad

### 11.1 RLS sobre nuevas tablas

```sql
alter table public.prep_stations enable row level security;
alter table public.prep_station_printers enable row level security;
alter table public.device_printer_bindings enable row level security;
alter table public.printer_health enable row level security;
alter table public.device_agents_health enable row level security;

-- Política básica: solo miembros del business
create policy "prep_stations_select" on public.prep_stations
  for select using (
    business_id in (select business_id from public.memberships where user_id = auth.uid())
  );
-- Análogas para insert/update/delete con verificación de rol owner/admin
```

### 11.2 Validaciones

- `connection_config` debe validarse según `transport` (función trigger en BD).
- IP debe ser válida (regex en app).
- MAC BT debe ser válida (regex).
- Solo usuarios con rol `admin`/`owner` pueden modificar impresoras.

### 11.3 Datos sensibles

- `connection_config.pin` (BT) se almacena hasheado.
- Logs no deben loggear payloads completos (pueden contener nombres de clientes).

---

## 12. Performance

### 12.1 Targets

- Latencia mediana de impresión: <500ms (LAN local), <1s (USB local), <2s (BT local), <3s (cross-device).
- Throughput: 60+ tickets/min sostenido por agent.
- Concurrencia: agent procesa hasta 10 jobs en paralelo (un transport por job).

### 12.2 Caché

- `prep_station_printers` y `product_prep_stations`: caché en memoria con invalidación por Supabase Realtime.
- `printer_health`: stream en vivo, no caché.

### 12.3 Optimizaciones

- Pool de conexiones TCP a impresoras LAN (mantener abierta 30s).
- Batch de updates de `printer_health` cada N segundos.
- Comprimir payloads grandes con gzip antes de encolar.

---

## 13. Roadmap futuro

- **Kitchen Display System (KDS)**: en lugar de imprimir, mostrar en pantalla con bumps. Proyecto separado.
- **Predictive routing**: ML para detectar qué impresora se está saturando y rutear a alternativas.
- **Cloud print bridge**: cliente sin agent local que usa una API REST (para integraciones).
- **Print proxy compartido**: una Raspberry Pi central que sirve a múltiples devices sin agent.
- **Self-healing**: agent detecta atasco/error y reinicia impresora vía red (si soporta SNMP).

---

## Apéndice — Referencias

- [ESC/POS Command Reference (Epson)](https://reference.epson-biz.com/modules/ref_escpos/index.php)
- [Code page index](https://en.wikipedia.org/wiki/Code_page)
- [libusb docs](https://libusb.info/)
- [Bluetooth SPP profile spec](https://www.bluetooth.com/specifications/specs/serial-port-profile-1-2/)
- [CUPS programming](https://www.cups.org/doc/api-cups.html)
- [Supabase Realtime](https://supabase.com/docs/guides/realtime)
- Migraciones existentes relevantes:
  - [20260312_0027_print_jobs_rls_fix.sql](../supabase/migrations/20260312_0027_print_jobs_rls_fix.sql)
  - [20260401_0002_device_bound_cash_sessions.sql](../supabase/migrations/20260401_0002_device_bound_cash_sessions.sql)
  - [20260308_0022_user_access_control.sql](../supabase/migrations/20260308_0022_user_access_control.sql)
