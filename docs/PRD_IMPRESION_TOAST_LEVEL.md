# PRD — Arquitectura de Impresión Nivel Toast (MangoPOS)

> **Estado:** Borrador para aprobación
> **Owner:** Cristian Gómez
> **Fecha:** 2026-05-20
> **Duración estimada:** 4-6 semanas (un dev full-time) / 8-12 semanas (parcial)
> **Documentos relacionados:** [GUIA_USUARIO_IMPRESION.md](GUIA_USUARIO_IMPRESION.md), [MANUAL_TECNICO_IMPRESION.md](MANUAL_TECNICO_IMPRESION.md), [PRD_CAJA_PROFESIONAL.md](PRD_CAJA_PROFESIONAL.md)

---

## 1. Visión

Convertir el módulo de impresión de MangoPOS en una **plataforma profesional unificada**, comparable o superior a Toast/Square for Restaurants, que soporte de primera clase **LAN, Bluetooth, USB y CUPS**, con ruteo lógico por estación de preparación, fallback automático, observabilidad en tiempo real, y selección de destino al imprimir.

### Frase clave

> La aplicación no debe saber si una impresora es LAN, BT o USB. Solo dice _"imprime esto en Cocina Caliente"_. Una capa de transporte se encarga del resto, con cola persistente, reintentos automáticos y salud monitoreada.

---

## 2. Estado actual (auditoría)

**Lo que ya funciona:**

- Catálogo de impresoras con flags `prints_orders`, `prints_prebills`, `prints_receipts` ([printing_repository.dart:212](../lib/data/repositories/printing_repository.dart#L212)).
- Auto-selección por caja: `cash_registers.receipt_printer_id` se usa primero ([table_order_screen.dart:3345-3367](../lib/presentation/sales/view/table_order_screen.dart#L3345)).
- Fallback a impresora "por área" si no hay asignada a la caja.
- Soporte LAN (TCP a puerto 9100) en producción.
- Paquetes BT/USB en `pubspec.yaml` pero **no usados activamente**.
- Cola persistente `print_jobs` ([20260312_0027_print_jobs_rls_fix.sql](../supabase/migrations/20260312_0027_print_jobs_rls_fix.sql)) — infraestructura lista pero subutilizada.
- Agente local en `agent/` — base existe pero falta evolución.
- División de comandas por impresora de producción según asignación de productos.

**Huecos identificados:**

| Hueco | Impacto |
|---|---|
| No hay selector de impresora al momento de imprimir | Cajero/mesero no puede elegir destino |
| Una impresora por rol (no multi-destino con prioridad) | No hay fallback automático |
| Sin concepto de `prep_station` (estación lógica) | Difícil escalar a layouts complejos |
| Sin binding device ↔ impresora USB/BT | BT/USB no usables en multi-device |
| Sin monitoreo de salud (`printer_health`) | No se sabe si una impresora cayó |
| Sin reintentos exponenciales / notificación de fallo | Tickets perdidos en silencio |
| Sin transporte unificado abstracto | Cada tecnología es código separado |
| Sin "destinos especiales" (pantalla, WhatsApp) | Limitado a impresión física |

---

## 3. Diferenciadores objetivo (vs. Toast)

| Feature | Toast | Esta plataforma |
|---|---|---|
| LAN nativo | ✅ | ✅ |
| Bluetooth first-class | Limitado | ✅ |
| USB first-class | Limitado | ✅ |
| Hardware propietario | Solo Toast | **Cualquiera** |
| Multi-fallback por estación | ✅ | ✅ |
| Cambio de transport sin tocar código | ❌ | ✅ |
| Time-based routing | ❌ | ✅ (fase 5) |
| Modo degradado (audio fallback) | Parcial | ✅ (fase 4) |
| Multi-codepage por impresora | Limitado | ✅ |
| WhatsApp opcional | ❌ | ✅ (fase 5) |
| Re-print desde historial | ✅ | ✅ |
| Dashboard salud en vivo | ✅ | ✅ |

---

## 4. Arquitectura

### 4.1 Capas

```
┌────────────────────────────────────────────────────────────┐
│ CAPA 1 — App Flutter                                       │
│ printOrchestrator.send(ticket, destination: "Cocina Cal.") │
└────────────────────────┬───────────────────────────────────┘
                         │
┌────────────────────────▼───────────────────────────────────┐
│ CAPA 2 — Orchestrator                                      │
│ • Resuelve prep_station → printers (primary + fallback)    │
│ • Divide ticket por destino                                │
│ • Decide ruta directa vs queue                             │
│ • Emite print_jobs                                         │
└────────────────────────┬───────────────────────────────────┘
                         │
┌────────────────────────▼───────────────────────────────────┐
│ CAPA 3 — Cola persistente (print_jobs)                     │
│ • Estado: pending / in_progress / printed / failed / dead  │
│ • target_device_id, target_printer_id, payload, retries    │
└────────────────────────┬───────────────────────────────────┘
                         │
        ┌────────────────┼─────────────────────┐
        │                │                     │
┌───────▼────────┐ ┌─────▼──────┐    ┌─────────▼──────────┐
│ Local agent    │ │ Direct     │    │ Cross-device       │
│ (transports:   │ │ in-app     │    │ routing (cloud)    │
│ LAN/USB/BT/    │ │ LAN/BT     │    │                    │
│ Serial/CUPS)   │ │            │    │                    │
└───────┬────────┘ └─────┬──────┘    └─────────┬──────────┘
        └────────────────┴─────────────────────┘
                         │
                         ▼
                   [IMPRESORAS]
```

### 4.2 Modelo de datos nuevo

Migraciones a crear (Fase 1):

```sql
-- 1) Extensión de printers
alter table public.printers
  add column transport text not null default 'lan'
    check (transport in ('lan','usb','bluetooth','serial','cups')),
  add column purpose text not null default 'general'
    check (purpose in ('receipt','precheck','kitchen','label','general')),
  add column connection_config jsonb not null default '{}'::jsonb,
  add column codepage text default 'CP858',
  add column paper_width_mm int default 80,
  add column last_seen_at timestamptz,
  add column last_error text;

-- 2) Estaciones de preparación (capa lógica)
create table public.prep_stations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid references public.branches(id) on delete cascade,
  name text not null,
  color text default '#FF6B35',
  display_order int default 0,
  is_active boolean default true,
  created_at timestamptz default now()
);

-- 3) Asignación impresoras ↔ estación (N:M con prioridad)
create table public.prep_station_printers (
  prep_station_id uuid not null references public.prep_stations(id) on delete cascade,
  printer_id uuid not null references public.printers(id) on delete cascade,
  priority int not null default 1,
  primary key (prep_station_id, printer_id)
);

-- 4) Productos ↔ estaciones (N:M)
create table public.product_prep_stations (
  product_id uuid not null references public.products(id) on delete cascade,
  prep_station_id uuid not null references public.prep_stations(id) on delete cascade,
  primary key (product_id, prep_station_id)
);

-- 5) Device ↔ impresora (para BT/USB locales)
create table public.device_printer_bindings (
  device_id text not null,
  printer_id uuid not null references public.printers(id) on delete cascade,
  is_local_owner boolean default true,
  paired_at timestamptz default now(),
  primary key (device_id, printer_id)
);

-- 6) Health de agente local
create table public.device_agents_health (
  device_id text primary key,
  business_id uuid references public.businesses(id) on delete cascade,
  last_heartbeat timestamptz default now(),
  agent_version text,
  os text,
  available_transports text[],
  metadata jsonb default '{}'::jsonb
);

-- 7) Health de cada impresora
create table public.printer_health (
  printer_id uuid primary key references public.printers(id) on delete cascade,
  status text not null default 'unknown'
    check (status in ('online','offline','low_paper','no_paper','cover_open','error','unknown')),
  last_checked_at timestamptz default now(),
  consecutive_failures int default 0,
  details jsonb default '{}'::jsonb
);

-- 8) Extender print_jobs
alter table public.print_jobs
  add column target_device_id text,
  add column transport text,
  add column attempts int default 0,
  add column max_attempts int default 5,
  add column next_attempt_at timestamptz,
  add column error_log jsonb default '[]'::jsonb,
  add column idempotency_key uuid;

create index idx_print_jobs_pending_for_device
  on public.print_jobs (target_device_id, status, next_attempt_at)
  where status in ('pending','retry');
```

### 4.3 Transports plugin (en el agent)

```dart
abstract class PrinterTransport {
  Future<TransportResult> sendRaw(Uint8List escposPayload, PrinterConfig p);
  Future<PrinterHealth> probeHealth(PrinterConfig p);
  Future<List<DiscoveredPrinter>> discover();
}

class LanTransport extends PrinterTransport { ... }
class UsbTransport extends PrinterTransport { ... }
class BluetoothTransport extends PrinterTransport { ... }
class SerialTransport extends PrinterTransport { ... }
class CupsTransport extends PrinterTransport { ... }
```

---

## 5. Roadmap por fases

### Fase 0 — Preparación (3-5 días)

**Objetivo:** Tener base estable antes de tocar nada.

- [ ] Auditoría profunda del código actual (`lib/services/printing/`, `lib/core/printing/`, `agent/`).
- [ ] Documentar APIs y flujos actuales.
- [ ] Identificar tests existentes y cobertura.
- [ ] Definir métricas de éxito (tickets/min, tasa de fallos actual).
- [ ] Crear branch `feature/printing-v2` y plan de releases.

**Deliverable:** Reporte de auditoría + branch listo.

---

### Fase 1 — Fundación de datos (1-1.5 semanas)

**Objetivo:** Modelo de datos nuevo, sin romper lo existente.

- [ ] Migraciones SQL (las 8 listadas en §4.2).
- [ ] Backfill: convertir impresoras actuales al nuevo modelo (`transport='lan'`, asignar `purpose` según flags).
- [ ] Generar `prep_stations` por defecto desde "áreas" actuales si existen.
- [ ] Modelos Dart actualizados (`PrinterConfig`, `PrepStation`, `DevicePrinterBinding`).
- [ ] Repository methods nuevos (`getPrepStations`, `getPrintersForStation`, etc.).
- [ ] Tests unitarios del repository.
- [ ] Migración inversa (`ROLLBACK`) probada.

**Deliverable:** BD con estructura nueva + modelos + tests. Sin cambios visibles al usuario aún.

**Riesgo:** Backfill incorrecto rompe configuración existente. **Mitigación:** ejecutar en staging primero, snapshot antes.

---

### Fase 2 — Orquestador + selector de destino (1-1.5 semanas)

**Objetivo:** UI nueva de selección + lógica de orquestación.

- [ ] `PrintOrchestrator` service en `lib/services/printing/`.
- [ ] Selector de destino (bottom sheet) al presionar "Pre-Cuenta", "Despacho", "Recibo".
- [ ] Lógica: si solo hay 1 destino → imprime directo; si hay >1 → muestra selector.
- [ ] Recordar última elección por device en `SharedPreferences`.
- [ ] Pantalla admin: gestionar `prep_stations` y asignar productos.
- [ ] Pantalla admin: asignar impresoras a estación con prioridad (drag&drop).
- [ ] Tests E2E del selector.

**Deliverable:** Usuario final puede ver el selector y elegir. Admin puede configurar estaciones.

---

### Fase 3 — Agent expandido + transports (2 semanas)

**Objetivo:** Soportar BT y USB de primera clase.

- [ ] Evolucionar `agent/` para polling de `print_jobs` (en lugar de push directo).
- [ ] Implementar `LanTransport`, `UsbTransport`, `BluetoothTransport` con interfaz unificada.
- [ ] Detección automática de impresoras: LAN (mDNS + escaneo), USB (VID/PID), BT (SPP pareadas).
- [ ] Pantalla "Descubrir impresoras" que muestra las detectadas y permite agregarlas.
- [ ] Vinculación device ↔ impresora BT/USB (UI de pareo).
- [ ] Cola local SQLite en el agent para resiliencia offline.
- [ ] Heartbeat cada 30s a `device_agents_health`.
- [ ] Tests de integración con impresoras mock.

**Deliverable:** Una impresora BT o USB se descubre, se vincula a un device, y se imprime en ella desde cualquier app del business.

**Riesgo:** Drivers BT/USB son frágiles por OS. **Mitigación:** matrix de testing en macOS, Windows, Android.

---

### Fase 4 — Resiliencia + observabilidad (1.5 semanas)

**Objetivo:** Saber qué pasa en todo momento y recuperarse de fallos solo.

- [ ] Fallback automático: si primary falla, prueba secondary de la misma `prep_station`.
- [ ] Reintentos con backoff exponencial (1s, 2s, 4s, 8s, 16s).
- [ ] Dashboard de salud en vivo (`/settings/printing/health`).
- [ ] Notificaciones push al cajero/admin cuando una impresora cae.
- [ ] Re-print manual desde historial de tickets.
- [ ] Métricas: tickets/min, tasa de éxito, tiempo promedio, fallos por impresora.
- [ ] Modo degradado: si no hay impresora disponible, muestra ticket en pantalla con voz.

**Deliverable:** Dashboard funcionando + notificaciones + re-print.

---

### Fase 5 — Destinos extra (opcional, 1 semana)

**Objetivo:** WhatsApp opcional + extras.

- [ ] Generar PDF de pre-cuenta / recibo.
- [ ] Botón "Enviar por WhatsApp" en el selector (abre wa.me con PDF).
- [ ] Validación: si la orden no tiene teléfono del cliente, pedirlo.
- [ ] Time-based routing (impresora A en horario pico, A+B fuera de pico).
- [ ] Múltiples copias (imprimir aquí Y en backup simultáneamente).

**Deliverable:** WhatsApp funcionando + time-based opcional.

---

### Fase 6 — Pulido + release (3-5 días)

- [ ] QA completo en staging con configuraciones reales (LAN sola, BT sola, mix).
- [ ] Documentación final (esta guía + manual técnico actualizados).
- [ ] Migración de clientes existentes a v2 (script automático).
- [ ] Capacitación equipo soporte.
- [ ] Release notes y comunicación a clientes.

---

## 6. Métricas de éxito

| Métrica | Hoy (baseline) | Objetivo |
|---|---|---|
| Tasa de tickets impresos exitosos | TBD (medir Fase 0) | ≥99.5% |
| Tiempo desde "enviar" hasta papel impreso | TBD | <2s mediana |
| Tickets perdidos por día (sin notificar) | Desconocido | 0 |
| Transports soportados activamente | 1 (LAN) | 4 (LAN, BT, USB, CUPS) |
| Tiempo de configuración inicial cliente nuevo | ~1-2h | <30 min |
| Llamadas de soporte por impresión / mes | TBD | -50% |
| Clientes capaces de auto-configurar | <10% | >50% |

---

## 7. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| Migración rompe configuraciones existentes | Media | Alto | Backfill probado en staging, rollback automático, dry-run obligatorio |
| BT inestable en Android viejos | Alta | Medio | Documentar versiones soportadas, fallback a LAN sugerido |
| USB requiere permisos OS específicos | Alta | Medio | Instalador del agent maneja permisos automáticamente |
| Performance del orchestrator con 10+ impresoras | Baja | Medio | Tests de carga, caché de resoluciones |
| Resistencia del usuario al nuevo flujo | Media | Bajo | Default = auto-seleccionar (como hoy), selector solo cuando >1 destino |
| Cambio breaking en API de Supabase | Baja | Alto | Pin versión + tests de integración |
| Bugs en drivers ESC/POS específicos (codepage, corte) | Alta | Bajo | Tabla de quirks por modelo, profile por impresora |

---

## 8. Out of scope (no esta versión)

- KDS (Kitchen Display System) — proyecto separado, en `lib/presentation/kds/`.
- Server banking (cada mesero su propia caja) — fase futura.
- Coursing (entradas → mains → postres con timing) — fase futura.
- Integración con Toast Go u hardware propietario — no aplica.
- Multi-tenant printing entre sucursales (cross-location) — no es necesidad operativa real.

---

## 9. Equipo y responsabilidades

| Rol | Quién | % dedicación |
|---|---|---|
| Tech lead | TBD | 100% durante implementación |
| Backend / SQL | TBD | 50% Fases 1, 4 |
| Frontend Flutter | TBD | 100% Fases 2, 4 |
| Agent / native | TBD | 100% Fase 3 |
| QA | TBD | 50% Fase 6 |
| Soporte (capacitación) | TBD | 25% Fase 6 |

---

## 10. Aprobación

| Rol | Nombre | Firma | Fecha |
|---|---|---|---|
| Product owner | | | |
| Tech lead | | | |
| Cliente referente | | | |

---

## Apéndice A — Decisiones tomadas

- **2026-05-20:** Alcance acordado: arquitectura completa nivel Toast (no MVP parcial).
- **2026-05-20:** Destinos a soportar: impresoras físicas + WhatsApp opcional.
- **2026-05-20:** Email y otros destinos especiales: fuera de scope inicial.
- **2026-05-20:** Implementación fase a fase con revisión entre cada una.

## Apéndice B — Glosario

- **prep_station**: estación de preparación lógica (ej. "Cocina Caliente", "Bar"). Capa entre productos e impresoras.
- **transport**: tecnología de conexión a la impresora (LAN, USB, BT, Serial, CUPS).
- **purpose**: rol de la impresora (receipt, precheck, kitchen, label, general).
- **binding**: vinculación device ↔ impresora (necesario para BT/USB).
- **orchestrator**: capa que decide a qué impresora(s) va cada ticket.
- **agent**: proceso local en PC/tablet que ejecuta la impresión física.
