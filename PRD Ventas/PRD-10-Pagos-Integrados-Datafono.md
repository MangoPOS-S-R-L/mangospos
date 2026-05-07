# PRD 6 — Módulo de Pagos Integrados con Datáfono

**Programa**: Fiscal Stabilization Program
**Status**: Draft v0.1 — pendiente entrega de spec por parte de Azul
**Owner / DRI**: Cristian
**Pattern**: Strangler fig (consistente con PRD 5)
**Última actualización**: 2026-05-07

---

## 1. Contexto y motivación

MangoPOS hoy registra los pagos con tarjeta de forma **manual**: el cajero digita el monto en el datáfono Ingenico de Azul, espera la aprobación, y luego transcribe (frecuentemente con errores) el código de aprobación al POS. Las consecuencias actuales son:

- **Errores de digitación**: el monto cobrado en el datáfono no siempre coincide con el monto registrado en MangoPOS.
- **Pérdida de datos para conciliación**: no se persisten RRN, brand, últimos 4, ni voucher dentro del POS.
- **Voucher impreso por separado** del recibo NCF, lo que obliga al comerciante a graparlos manualmente.
- **Imposibilidad de auditoría** de transacciones declinadas, anuladas o "in-doubt" (aprobadas en datáfono pero no registradas en POS).
- **Fricción operativa** que ralentiza el cobro, especialmente en horas pico.

Este PRD introduce **integración total** entre MangoPOS y el datáfono Ingenico provisto por Azul, con MangoPOS como master del flujo de pago: envía el monto, recibe la aprobación, persiste todo el ciclo y dispara la impresión combinada de voucher + NCF.

---

## 2. Objetivos

### Primarios

| ID | Objetivo |
|----|----------|
| O1 | Al cerrar una venta, el cajero presiona "Cobrar con tarjeta" y el datáfono recibe el monto automáticamente, sin digitación. |
| O2 | Al aprobarse, MangoPOS recibe `authorization_code`, `RRN`, `card_brand`, `masked_pan`, y `voucher_text`; los persiste atados a la venta. |
| O3 | Toda transacción intentada (aprobada, declinada, timeout, error) queda registrada con request/response raw para auditoría. |
| O4 | Configuración por estación: cada caja conoce su datáfono asociado y puede tenerlo en TCP o Serial. |

### Secundarios

| ID | Objetivo |
|----|----------|
| O5 | Soporte para anulación (mismo lote, mismo día) desde MangoPOS. |
| O6 | Cierre de lote diario invocable desde MangoPOS. |
| O7 | Reconciliación automática de transacciones in-doubt vía consulta de última transacción al terminal. |
| O8 | Reporte de cierre de día con totales por marca, comparable contra el reporte de Azul. |

### Fuera de alcance (explícito)

- ❌ Devoluciones post-cierre (post-settlement refunds). Se aborda en PRD futuro.
- ❌ Soporte simultáneo con otros adquirentes (CardNet, Visanet). La arquitectura lo permitirá pero no se entrega un adapter alternativo en este PRD.
- ❌ SoftPOS / tap-to-phone.
- ❌ Pagos parciales (split tender) entre tarjeta y efectivo. PRD posterior.
- ❌ Tipping en el datáfono (propina capturada por el terminal). Inicialmente la propina se calcula en MangoPOS y viaja como parte del monto.

---

## 3. Decisiones arquitectónicas clave

### DA-1: Patrón puerto / adapter (hexagonal)

Se introduce `PaymentTerminalPort` como interfaz abstracta. El dominio de venta consume el puerto, **nunca conoce a Azul directamente**. Esto deja la puerta abierta para CardNet u otro adquirente sin reescribir la capa de checkout.

### DA-2: Transporte desacoplado del protocolo

`EcrTransport` abstrae TCP / Serial / Fake. El adapter Azul es agnóstico al transporte físico. Si Azul nos confirma TCP hoy y mañana cambia a Serial USB, solo se intercambia la implementación inyectada — sin tocar lógica de protocolo ni de negocio.

### DA-3: Strangler fig sobre el flujo de pago actual

El método de pago "Tarjeta" en MangoPOS gana una bandera `is_integrated`. Si está activa para la estación + tipo de pago, se invoca el puerto. Si no, fallback al flujo manual actual. Permite roll-out gradual por estación, con kill-switch inmediato.

### DA-4: Latin-1 obligatorio en framing

Los terminales Ingenico esperan ISO-8859-1 (latin1). Encodear en UTF-8 produce LRC inválido cuando hay acentos o `Ñ`. Convención: **todos los strings que viajan al transporte se encodean explícitamente con `latin1.encode()`**, prohibido `utf8`.

### DA-5: Cada intento de pago se persiste antes y después del exchange

Tabla `payment_attempts` con `request_raw_hex` y `response_raw_hex`. Crítico para:
- Auditoría regulatoria.
- Resolución de in-doubt.
- Debug remoto cuando un comerciante reporta "el datáfono cobró pero MangoPOS no lo registró".

### DA-6: FakeEcrAdapter es first-class citizen

Para desarrollo, demos, QA y entrenamiento, `FakeEcrAdapter` simula el flujo completo (incluso latencia y declinaciones por monto, ej. `RD$13.00 → declinada`) sin terminal real. Disponible **en builds dev y staging**, removido en producción vía feature flag.

### DA-7: Mutex por `payment_device_id`

Un datáfono no puede atender dos ventas simultáneas. El orchestrator mantiene un lock asíncrono por device_id que serializa las operaciones. Timeout de adquisición de lock: 5 s.

### DA-8: Estado `in_doubt` es un ciudadano de primera clase

Si tras enviar la venta el response no llega (timeout, cable, kernel panic), la venta queda en estado `pending_reconciliation` y la `payment_attempt` en `in_doubt`. **Nunca se asume aprobada ni declinada** — se reconcilia explícitamente.

---

## 4. Modelo de datos (Supabase)

### Tabla `payment_devices`

```sql
create table public.payment_devices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  alias text not null,                            -- "Caja 1 - Azul"
  acquirer text not null check (acquirer in ('azul')),
  transport_kind text not null check (transport_kind in ('tcp', 'serial', 'fake')),
  transport_config jsonb not null,                -- {host,port} o {com_port,baud}
  terminal_model text,                            -- 'iCT250', 'Move5000', 'Lane3000'
  merchant_id text,                               -- MID asignado por Azul
  terminal_id text,                               -- TID
  is_active boolean not null default true,
  last_ping_at timestamptz,
  last_ping_ok boolean,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index on payment_devices (organization_id) where is_active;
```

### Tabla `station_payment_devices` (asociación 1:1)

```sql
create table public.station_payment_devices (
  station_id uuid primary key references stations(id),
  payment_device_id uuid not null references payment_devices(id),
  assigned_at timestamptz not null default now()
);
```

### Tabla `payment_attempts`

```sql
create table public.payment_attempts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  payment_device_id uuid not null references payment_devices(id),
  sale_id uuid references sales(id),

  operation text not null check (operation in (
    'sale','void','refund','batch_close','last_tx_query','ping'
  )),

  amount numeric(12,2),
  itbis numeric(12,2),
  tip numeric(12,2),

  status text not null check (status in (
    'pending','approved','declined','timeout','error','in_doubt','reconciled'
  )),

  acquirer_reference text,
  authorization_code text,
  rrn text,
  card_brand text,
  masked_pan text,                                -- ej: "**** **** **** 1234"
  voucher_text text,

  request_raw_hex text,
  response_raw_hex text,

  request_started_at timestamptz not null default now(),
  request_ended_at timestamptz,

  error_code text,
  error_message text,

  reconciled_at timestamptz,
  reconciled_by uuid references users(id)
);

create index on payment_attempts (organization_id, sale_id);
create index on payment_attempts (payment_device_id, request_started_at desc);
create index on payment_attempts (status) where status in ('in_doubt','timeout','pending');
```

### Migración no destructiva en `sales`

```sql
alter table public.sales add column if not exists
  payment_status text default 'completed'
  check (payment_status in ('completed','pending_reconciliation','reconciled','failed'));
```

### RLS

Todas las tablas siguen el patrón estándar de la plataforma: policy por `organization_id` matching el JWT claim. Los `payment_attempts` solo son visibles para usuarios con rol `cashier` (parcial, sin `request_raw_hex`) o `admin` (completo).

---

## 5. Arquitectura de código

```
lib/payments/
├── domain/
│   ├── payment_terminal_port.dart       # interfaz
│   ├── payment_result.dart              # DTO
│   ├── payment_operation.dart           # enum
│   ├── payment_status.dart              # enum
│   └── payment_device.dart              # entidad
├── transport/
│   ├── ecr_transport.dart               # interfaz
│   ├── tcp_transport.dart               # dart:io.Socket
│   ├── serial_transport.dart            # flutter_libserialport (feature-flagged)
│   └── fake_transport.dart
├── framing/
│   ├── ecr_framing.dart                 # STX/ETX/LRC (Latin-1)
│   └── ack_nak_handler.dart
├── adapters/
│   ├── azul_ecr_adapter.dart            # implementa PaymentTerminalPort
│   └── fake_ecr_adapter.dart
├── persistence/
│   ├── payment_attempts_repository.dart
│   └── payment_devices_repository.dart
├── orchestration/
│   ├── payment_orchestrator.dart        # locks, in-doubt, retry
│   └── payment_state_machine.dart       # idle → sending → ack → response → idle
└── ui/
    ├── settings/
    │   ├── payment_devices_screen.dart
    │   ├── add_edit_device_dialog.dart
    │   ├── test_connection_button.dart
    │   └── device_status_indicator.dart
    └── checkout/
        ├── card_payment_modal.dart
        └── payment_progress_indicator.dart
```

---

## 6. Plan de fases

### F1 — Cimientos (sin terminal real)

| Sub-fase | Entregable |
|----------|------------|
| F1.1 | Migration de Supabase con `payment_devices`, `station_payment_devices`, `payment_attempts`, columna `payment_status` en `sales`, y RLS policies. |
| F1.2 | `PaymentTerminalPort`, DTOs (`PaymentResult`), enums (`PaymentOperation`, `PaymentStatus`), entidad `PaymentDevice`. |
| F1.3 | `FakeEcrAdapter` con reglas determinísticas de simulación: aprobaciones por defecto, declinaciones por monto (ej. `13.00`, `666.00`), timeout (`9999.00`). |
| F1.4 | `payment_attempts_repository` y `payment_devices_repository` con tests unitarios. |

**Definition of Done F1**: el dominio de venta puede invocar `paymentPort.sale(amount: 100)` y recibir un `PaymentResult` simulado, persistido en BD, sin que exista hardware. Cobertura de tests ≥ 90%.

### F2 — Capa de transporte y framing

| Sub-fase | Entregable |
|----------|------------|
| F2.1 | `EcrTransport` interface + `TcpTransport` con `dart:io.Socket`, manejo de timeouts, reconexión. |
| F2.2 | `EcrFraming` con tests exhaustivos: LRC válido/inválido, mensaje partido en chunks TCP, ACK/NAK suelto, STX duplicado, payload con caracteres `Ñ`/acentos. |
| F2.3 | `AckNakHandler` para el handshake half-duplex (envío → ACK → respuesta → ACK → EOT). |
| F2.4 | `SerialTransport` con `flutter_libserialport`, **detrás de feature flag**. No se construye si Azul confirma TCP en F3 kickoff. |

**Definition of Done F2**: tests unitarios al 100%; test de integración con un servidor TCP echo en `localhost` que recibe un mensaje framed, valida LRC, y responde un mensaje válido.

### F3 — Adapter Azul (gated por spec del adquirente)

> ⚠️ **Bloqueado** hasta recibir spec ECR de Azul + terminal de certificación.

| Sub-fase | Entregable |
|----------|------------|
| F3.1 | `_buildSaleMessage` y `_parseSaleResponse` siguiendo la spec de Azul. |
| F3.2 | Operaciones secundarias: `void`, `batch_close`, `last_tx_query`, `ping`. |
| F3.3 | `PaymentStateMachine` formal con manejo de timeouts por estado. |
| F3.4 | Mapeo de códigos de respuesta Azul → `PaymentStatus` + `error_code` legible. |
| F3.5 | Certificación con Azul: ejecutar test script provisto por ellos contra terminal de pruebas, obtener sign-off por escrito. |

**Definition of Done F3**: certificación Azul aprobada por escrito; tests de integración contra terminal real pasan al 100%.

### F4 — Configuración (UI Settings)

| Sub-fase | Entregable |
|----------|------------|
| F4.1 | Pantalla `Settings → Pagos → Datáfonos` con lista, agregar, editar, eliminar (soft-delete). |
| F4.2 | Diálogo "Agregar/editar datáfono" con UI dinámica según transporte (TCP vs Serial). |
| F4.3 | Botón "Probar conexión" que ejecuta `transport.open()` + `port.ping()` y muestra resultado en vivo. |
| F4.4 | Pantalla `Settings → Cajas` gana selector "Datáfono asociado". |
| F4.5 | Feature flag `payments.integrated_terminal` por organización; OFF = el módulo no aparece en settings (kill switch). |

**Definition of Done F4**: un admin puede registrar un datáfono nuevo, asociarlo a su caja, ejecutar un ping exitoso (contra `FakeEcrAdapter` en F4 inicial; contra Azul real post-F3), y al volver al checkout ver el botón "Cobrar con tarjeta integrado" disponible.

### F5 — Integración con flujo de checkout

| Sub-fase | Entregable |
|----------|------------|
| F5.1 | Modificación al modelo de `payment_methods`: bandera `is_integrated`. |
| F5.2 | En checkout, si la caja tiene datáfono activo + método tarjeta → flujo integrado; si no → flujo manual existente (strangler fig). |
| F5.3 | `CardPaymentModal` con estados visuales: enviando → esperando tarjeta → procesando → aprobado/declinado, con botón cancelar. |
| F5.4 | Mutex por `payment_device_id` en `PaymentOrchestrator`. |
| F5.5 | Manejo de timeout/in-doubt: la venta entra en estado `pending_reconciliation`. UI ofrece al cajero (a) marcarla como cobrada con código manual o (b) esperar reconciliación nightly. |

**Definition of Done F5**: una venta completa de inicio a fin (ring up → cobrar → aprobar → imprimir voucher + recibo NCF) funciona contra terminal de certificación de Azul.

### F6 — Voucher y encaje con PRD 5 (Unified Printing)

| Sub-fase | Entregable |
|----------|------------|
| F6.1 | El `voucher_text` retornado por Azul se inyecta en el unified printing module (PRD 5) como un `PrintJob` tipo `voucher`. |
| F6.2 | Plantilla de recibo combinado: voucher Azul + comprobante NCF en una sola impresión cuando la impresora lo permite (papel térmico continuo). |
| F6.3 | Reimpresión de voucher desde "Detalle de venta" → "Reimprimir voucher". |

**Definition of Done F6**: la venta integrada imprime un solo papel con voucher de Azul + NCF, formato aprobado por el cliente piloto.

### F7 — Reconciliación y cierre

| Sub-fase | Entregable |
|----------|------------|
| F7.1 | Job nightly que cruza `payment_attempts.status='in_doubt'` con `last_tx_query` al terminal o reporte de Azul. |
| F7.2 | Reporte "Cierre de día - Tarjetas" con totales por marca, desglose aprobadas/anuladas, monto neto. |
| F7.3 | Botón "Cerrar lote en datáfono" en cierre de turno. |
| F7.4 | Encaje con motor fiscal (PRD 1): los pagos integrados aparecen correctamente en reporte 607. |

**Definition of Done F7**: cierre de día puede ejecutarse desde MangoPOS; totales del POS coinciden con totales reportados por Azul (tolerancia 0.00).

---

## 7. UX de configuración (mockup textual)

### Settings → Pagos → Datáfonos

```
┌─────────────────────────────────────────────────────────────────┐
│  Datáfonos                                       [+ Agregar]   │
├─────────────────────────────────────────────────────────────────┤
│  Alias            Modelo        Estado    Caja        Acciones │
│  ─────────────────────────────────────────────────────────────  │
│  Caja 1 - Azul    Move 5000     🟢 OK    Caja 1      ⚙️  🗑️    │
│  Caja 2 - Azul    Move 5000     🔴 Off   Caja 2      ⚙️  🗑️    │
│  Test (Fake)      Simulado      🟢 OK    --          ⚙️  🗑️    │
└─────────────────────────────────────────────────────────────────┘
```

### Diálogo Agregar / Editar Datáfono

```
┌─ Nuevo datáfono ────────────────────────────────────┐
│  Alias:         [Caja 1 - Azul                    ] │
│  Adquirente:    [Azul ▼]                            │
│  Modelo:        [Ingenico Move 5000               ] │
│                                                      │
│  Conexión:      (•) TCP/IP   ( ) Serial USB         │
│                                                      │
│  Si TCP/IP:                                          │
│    Host:        [192.168.1.80                     ] │
│    Puerto:      [8080                             ] │
│                                                      │
│  Si Serial:                                          │
│    Puerto COM:  [COM3 ▼]                             │
│    Baud rate:   [9600 ▼]                             │
│                                                      │
│  Identificación Azul (provista por el adquirente):  │
│    MID:         [_______________________]            │
│    TID:         [_______________________]            │
│                                                      │
│  [Probar conexión]            [Cancelar] [Guardar]  │
└──────────────────────────────────────────────────────┘
```

"Probar conexión" muestra resultado en vivo:

- 🟢 **Conectado, ping OK** (latencia: 47 ms)
- 🔴 **Timeout** — no se pudo conectar a `192.168.1.80:8080` tras 10 s
- 🟡 **Conectado pero sin respuesta a ping** — verificar si el terminal está en modo integrado

### Settings → Cajas → Editar caja

Nuevo campo "Datáfono asociado" con dropdown poblado desde `payment_devices` activos.

---

## 8. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|--------|:-:|:-:|------------|
| Azul tarda meses en entregar spec | Alta | Alto | F1+F2+F4 avanzan con `FakeEcrAdapter`; F3 espera sin bloquear el resto |
| Spec entregada cambia frecuentemente | Media | Medio | Adapter aislado, cambios contenidos en `_build*`/`_parse*` |
| Terminal pasa de TCP a Serial (o viceversa) | Media | Bajo | `EcrTransport` desacoplado, intercambio sin tocar adapter |
| In-doubt no resuelto produce desfase contable | Media | Alto | F7.1 nightly + alertas + UI explícita para reconciliación manual |
| Caracteres especiales (Ñ, acentos) rompen LRC | Alta | Medio | DA-4 (latin1 obligatorio) + tests específicos en F2.2 |
| Concurrencia: 2 ventas al mismo terminal | Baja | Alto | DA-7 (mutex por device_id) |
| Voucher imprime en otra impresora que el NCF | Media | Bajo | F6 integra con PRD 5 unified printing |
| PCI scope inadvertido (logging de PAN completo) | Baja | Crítico | Sanitizar `request_raw_hex` antes de persistir; revisión de seguridad pre-prod |
| Caja se cuelga durante exchange (energía) | Media | Alto | Persistir attempt en `pending` antes de enviar; flujo de recovery al startup |

---

## 9. Dependencias y unknowns

### Bloqueantes para F3

- [ ] **Spec ECR de Azul** (formato de mensajes, códigos de operación, códigos de respuesta).
- [ ] **Confirmación de transporte** (TCP vs Serial vs USB-CDC).
- [ ] **Modelo del terminal a integrar** (afecta capacidades: NFC, propina, contactless).
- [ ] **Puerto e IP del terminal** en modo integrado (configurable o estático).
- [ ] **Terminal de certificación** + tarjetas de prueba.
- [ ] **Window de certificación** con técnico Azul.
- [ ] **Confirmación de aprovisionamiento remoto**: Azul tiene que cambiar el terminal de standalone a modo integrado.

### No bloqueantes pero pendientes de decisión

- [ ] **Política de retención** de `request_raw_hex` / `response_raw_hex` (90 días? 1 año? forever?).
- [ ] **PCI scope review**: aunque MangoPOS no toca PAN completo, `masked_pan` y voucher requieren sign-off.
- [ ] **Plan de soporte tier 1**: ¿quién atiende cuando el datáfono no responde? MangoPOS support o Azul.
- [ ] **Estrategia de roll-out**: ¿piloto con un comerciante específico o flag por organización?

---

## 10. Encaje con PRDs previos

| PRD | Encaje |
|-----|--------|
| PRD 1 (Tax engine) | Voucher integrado debe respetar formato NCF; `payment_attempts` aparece en reporte 607 con datos de tarjeta |
| PRD 2 (Venta Rápida) | "Cobrar con tarjeta" disponible también en flujo Venta Rápida si la caja tiene datáfono asociado |
| PRD 3 (Frontend refactor) | UI de settings sigue patrones del refactor; CardPaymentModal usa los componentes nuevos |
| PRD 5 (Unified Printing) | F6 inyecta voucher como PrintJob; reimpresión usa el mismo módulo |

---

## 11. Métricas de éxito (post-deploy)

| Métrica | Baseline | Objetivo a 30 días |
|---------|----------|---------------------|
| Tasa de errores de digitación de monto en pagos con tarjeta | ~3% (estimado) | 0% (eliminado por diseño) |
| Tiempo promedio de cobro con tarjeta | ~45 s | < 25 s |
| Tasa de in-doubt no resuelto al cierre de día | N/A | < 0.1% |
| Diferencia entre cierre POS y cierre Azul | manual | RD$0.00 (tolerancia 0) |
| Adopción del flujo integrado vs manual | 0% | > 90% en cajas con datáfono asociado |

---

## 12. Entregables y ritmo de comunicación

- Actualización de `STATE_OF_THE_PLATFORM.md` con sección "Pagos Integrados" tras cada fase.
- **Demo F1** (FakeEcrAdapter end-to-end) — sprint 1.
- **Demo F2 + F4** (settings UI con conexión simulada) — sprint 2.
- **Demo F5** (flujo end-to-end con FakeAdapter) — sprint 3.
- **Demo F3 + F5** (con terminal real Azul) — post-spec.
- **Demo F6 + F7** (voucher unificado + reconciliación) — sprint final.

---

## 13. Apertura del PRD: próximos pasos inmediatos

1. **Solicitar spec a Azul** (acción Cristian, esta semana). Llamar al 809-544-2985 / vozdelcliente@azul.com.do, pedir "integración ECR / punto de venta integrado". Confirmar transporte, modelo, IP/puerto.
2. **Crear migration F1.1** y mergearla a `develop`.
3. **Crear branch `feat/prd-06-payments-foundation`** para arrancar F1.
4. **Actualizar `STATE_OF_THE_PLATFORM.md`** con la sección "PRD 6 — En diseño".
5. **Bloquear espacio en agenda** para revisión semanal del avance de Azul.

---

*Fin de PRD 6.*
