# PRD — Roadmap a Offline 100% (Cero Gaps)

> **Tipo:** PRD prospectivo (plan de construcción). Complementa a [PRD_OFFLINE_ESTADO_ACTUAL.md](PRD_OFFLINE_ESTADO_ACTUAL.md).
> **Fecha:** 2026-05-31
> **Objetivo:** Llevar MangoPOS a operación **100% offline, sin un solo gap**, en un local con múltiples dispositivos y sin internet.
> **Decisiones tomadas por el dueño del producto:**
> 1. **KDS** → sincronización por **LAN real** (la pantalla de cocina funciona offline).
> 2. **NCF** → **rangos por dispositivo** (comprobante fiscal emitido en el acto, sin red).
> 3. **Arranque** → **offline desde cero** (sin depender de un provisioning online).

---

## 0. Lectura honesta antes de empezar (léelo)

El objetivo es alcanzable, pero tres de tus decisiones tienen aristas que **no se pueden programar para que desaparezcan** — solo se pueden gestionar. Quiero dejarlas explícitas ahora, no descubrirlas a mitad de camino:

1. **"Offline desde cero" no puede significar "sin ningún aprovisionamiento".**
   Para autenticar usuarios, validar PINs, conocer el catálogo y tener NCF, el terminal necesita *datos*. Si no vienen de internet, tienen que venir de **algún lado**: un archivo/QR de activación, o estar embebidos en el build. Embeber credenciales y catálogo en el binario por cliente es un **riesgo de seguridad serio** (secretos en disco, builds por tenant, sin revocación). 
   **Lo que este PRD propone:** un **aprovisionamiento local sin internet** — un paquete de activación firmado (archivo o QR) que se carga una vez en el primer equipo y se replica a los demás por LAN. No requiere internet, pero **sí requiere un acto físico de instalación**. Eso es lo más cercano a "desde cero" que es seguro. Si insistes en secretos embebidos, lo documentamos pero queda como riesgo aceptado por ti.

2. **NCF con rangos por dispositivo es una decisión fiscal, no solo técnica.**
   Partir la secuencia del negocio en sub-rangos por terminal **debe validarse con el contador/DGII del cliente**. Problemas a resolver sí o sí: huecos de numeración (rangos asignados que no se usan), agotamiento de rango offline (¿qué pasa si un terminal se queda sin números sin red?), y reconciliación al reconectar. Este PRD diseña el mecanismo, pero **la política fiscal la firma el cliente**.

3. **Multi-dispositivo offline = necesitas una autoridad local.**
   Si dos cajas operan sin internet sobre la misma mesa, divergen. La única forma de tener consistencia es un **Hub Local en la LAN** que sea la fuente de verdad mientras no hay internet, y que sincronice hacia Supabase al reconectar. Esto es el corazón del plan y de donde sale casi todo el esfuerzo.

> **Definición operativa de "100% offline" que adopta este PRD:**
> *Tras una activación local única (sin internet), cualquier conjunto de dispositivos del local puede tomar comandas, cobrar con NCF, despachar a cocina (pantalla + ticket), abrir/cerrar caja, mover efectivo, consultar reportes del día y operar indefinidamente sin conexión, reconciliando sin pérdida ni duplicación al reconectar.*

---

## 1. Inventario de gaps a cerrar

De [PRD_OFFLINE_ESTADO_ACTUAL.md §8](PRD_OFFLINE_ESTADO_ACTUAL.md):

| # | Gap | Severidad | Fase |
|---|---|---|---|
| G1 | **KDS** sin cache ni sync offline (pantalla ciega) | Crítica | F3 |
| G2 | **NCF/fiscal** no se emite offline | Crítica | F4 |
| G3 | **Movimientos de caja** (depósito/retiro/gasto) sin offline | Alta | F2 |
| G4 | **Cola de impresión offline** se llena pero no se drena | Alta | F2 |
| G5 | **Reportes/tickets** 100% online | Media | F5 |
| G6 | **Sin sync periódico** de respaldo | Media | F1 |
| G7 | **Acciones `failed` permanentes** sin dead-letter | Media | F1 |
| G8 | **Sin limpieza** de datos offline al logout/cambio de negocio | Alta (seguridad) | F1 |
| G9 | **Datos locales en texto plano** (PIN hash, órdenes, etc.) | Alta (seguridad) | F1 |
| G10 | **Arranque en frío** requiere red | Crítica | F0 |
| G11 | **Consistencia multi-terminal** offline inexistente | Crítica | F3 |
| G12 | `void_order` no persiste razón de auditoría | Baja | F2 |
| G13 | **Drift sin framework de migraciones** | Media | F1 |
| G14 | `CacheManager`: compresión y *enforcement* de tamaño no aplicados | Baja | F1 |
| G15 | **Sync bidireccional** (server→device) ausente | Media | F6 |

---

## 2. Arquitectura objetivo

### 2.1 El Hub Local (pieza central nueva)

Se evoluciona el agente local de impresión ([lib/core/agent/mobile_print_agent.dart](../lib/core/agent/mobile_print_agent.dart), servidor HTTP en `0.0.0.0:4000`) hacia un **Hub Local POS**: un servicio en LAN que, cuando no hay internet, es la **fuente de verdad** del local.

```
                 INTERNET PRESENTE                    SIN INTERNET
   ┌───────────────────────────────┐     ┌───────────────────────────────┐
   │  Cada device ↔ Supabase        │     │   Devices ↔ HUB LOCAL (LAN)    │
   │  (como hoy)                    │     │   Hub = autoridad del local    │
   │  Hub solo observa/replica      │     │   Hub encola hacia Supabase    │
   └───────────────────────────────┘     └───────────────────────────────┘
                     │                                   │
                     └──────────  Al reconectar  ────────┘
                        El hub drena su outbox a Supabase,
                        baja cambios del server, reconcilia.
```

**Responsabilidades del Hub Local:**
- Mantener estado autoritativo local (órdenes, items, pagos, sesiones de caja, estado KDS) en SQLite.
- Exponer API LAN (HTTP/WebSocket) para que los terminales lean/escriban y reciban *push* (esto alimenta KDS offline — G1/G11).
- **Asignar NCF** desde el rango del negocio/dispositivo (G2).
- Mantener su propia **outbox** hacia Supabase y reconciliar al reconectar.
- Descubrirse por **mDNS** (ya existe la infra, [lib/core/printing/agent_discovery.dart](../lib/core/printing/agent_discovery.dart)).
- Elección de líder: un device es Hub; si cae, otro toma el rol (failover).

**Topología de despliegue:** el Hub puede correr en (a) una de las tablets POS, (b) el equipo donde corre el print agent, o (c) un mini-PC dedicado. El cliente elige; el software soporta los tres.

### 2.2 Modos de operación de cada terminal

| Modo | Condición | Escribe contra | Lee de |
|---|---|---|---|
| **Cloud** | Internet OK, hub no requerido | Supabase | Supabase + caches |
| **Hub** | Sin internet, hub LAN presente | Hub Local (LAN) | Hub Local |
| **Solo** | Sin internet y sin hub | Cola local propia (como hoy) | Snapshots locales |

El **modo Solo** es el offline actual (ya implementado). El **modo Hub** es lo nuevo y lo que cierra los gaps multi-dispositivo y KDS.

### 2.3 Identidad, idempotencia y reloj

- **Todo ID se genera en cliente** (UUID v4) — ya es así. El server nunca inventa IDs en el camino crítico.
- **Idempotencia de extremo a extremo:** la dedup por `op_id` + `fingerprint` (ya existe) se extiende al Hub y a Supabase (constraints únicos server-side por `op_id`).
- **Reloj:** se preserva `*_at` generado en cliente (ya se hace con `paid_at`). El Hub estampa además su `received_at` para ordenar eventos LAN.

---

## 3. Fases

> Cada fase es entregable e independiente. Orden por dependencia y por valor/riesgo. Las fases F0–F2 endurecen y completan el offline **mono-dispositivo** actual; F3–F4 traen el Hub LAN, KDS y NCF; F5–F6 cierran reportes y bidireccionalidad.

---

### F0 — Aprovisionamiento sin internet (G10)

**Objetivo:** que un equipo recién instalado pueda activarse y operar sin haber tenido nunca internet.

**Diseño:**
- **Paquete de activación firmado** (`.mpkg` o QR encadenado): contiene `business_id`, `device_token`, roster inicial (hashes bcrypt), catálogo base, configuración fiscal y **rango NCF asignado a ese device** (ver F4). Firmado con clave del negocio para que no sea falsificable.
- Se genera **online una vez** (desde un equipo con red, o desde el backoffice) y se transfiere por archivo/QR/USB.
- El primer equipo activado puede **re-emitir** paquetes para los demás por LAN (vía Hub).
- `main.dart`: si Supabase init falla y existe paquete de activación válido → arrancar en **modo Hub/Solo** sin bloquear.

**Server/migración:** RPC `fn_generate_activation_package(business_id, device_name)` que arma y firma el paquete y reserva el rango NCF.

**Riesgos:** robo del paquete = acceso al negocio → mitigar con expiración + revocación de device_token al reconectar + cifrado en reposo (F1/G9).

**Aceptación:** instalar app en equipo nuevo en modo avión + cargar paquete → login por PIN, ver catálogo, tomar orden, cobrar con NCF.

---

### F1 — Endurecimiento del núcleo actual (G6, G7, G8, G9, G13, G14)

**Objetivo:** dejar el offline mono-dispositivo sólido, seguro y mantenible. **No requiere el Hub.**

1. **Sync periódico de respaldo (G6):** timer que dispara `syncPendingActions` cada N min **si hay pendientes y hay red**, independiente del stream de reconexión. Archivo: [offline_pos_service.dart](../lib/core/offline/offline_pos_service.dart) + un `Timer.periodic` en el arranque de servicios ([main.dart](../lib/main.dart)).
2. **Dead-letter (G7):** tope de intentos (p. ej. 8); al superarlo, mover a estado `dead` con `lastError`; visor en la UI del shell para inspeccionar/reintentar/descartar manualmente. Tabla Drift: columna `status='dead'` ya cabe.
3. **Limpieza al logout / cambio de negocio (G8):** `clearAllOfflineData(businessId)` que borra `offline_*`, snapshots, cola, caches y mappings del negocio saliente. Invocar en logout y en `selectBusiness`. **Bloquear logout si hay cola pendiente sin sincronizar** (avisar al cajero).
4. **Cifrado en reposo (G9):** mover snapshots de órdenes y roster a almacenamiento cifrado (extender uso de `flutter_secure_storage` o cifrar el JSON con clave derivada del device_token). PIN hashes ya son bcrypt; órdenes/pagos pasan a cifrado.
5. **Framework de migraciones Drift (G13):** implementar `MigrationStrategy` en [offline_queue_db.dart](../lib/core/offline/storage/offline_queue_db.dart) y subir `schemaVersion` con `onUpgrade`. Necesario antes de que el esquema local crezca (F3/F4 agregan tablas).
6. **CacheManager (G14):** aplicar compresión y *enforcement* de 30MB (evicción LRU por módulo). Menor.

**Aceptación:** logout limpia todo; una acción que falla 8 veces va a dead-letter visible; reinicios con cola pendiente nunca pierden datos; datos sensibles ilegibles en disco.

---

### F2 — Completar acciones offline faltantes (G3, G4, G12)

**Objetivo:** que toda mutación del POS tenga ruta offline. **No requiere el Hub.**

1. **Movimientos de caja (G3):** nuevo tipo de acción `cash_transaction` (deposit/withdrawal/expense). Encolar en [cashier_repository.dart:553](../lib/data/repositories/cashier_repository.dart) cuando no hay red; replay contra `fn_cash_transaction_create`. Manejar el caso de autorización con PIN de supervisor **offline** (validar contra roster local).
2. **Drenar cola de impresión (G4):** que `syncPendingActions` (o el Hub) **consuma** `offline_print_queue_{businessId}` ([offline_pos_service.dart:349](../lib/core/offline/offline_pos_service.dart)) y reintente la impresión/escalado al reconectar. Hoy se escribe pero nadie lee.
3. **Razón de void (G12):** persistir la nota de auditoría en el replay de `void_order` (`appendVoidAuditNote` → `table_sessions.notes`) — hoy se pierde ([offline_pos_service.dart:1164](../lib/core/offline/offline_pos_service.dart)).

**Aceptación:** registrar un retiro de caja en modo avión y verlo reflejado tras sync; un ticket que no pudo imprimirse offline sale solo al reconectar; un void offline conserva su razón.

---

### F3 — Hub Local + KDS offline + consistencia multi-terminal (G1, G11)

**Objetivo:** la pieza grande. Pantalla de cocina y consistencia entre dispositivos sin internet.

1. **Servicio Hub Local:** evolucionar [mobile_print_agent.dart](../lib/core/agent/mobile_print_agent.dart) a un servidor con SQLite autoritativo y API:
   - `POST /ops` (encolar mutación con `op_id`/fingerprint), `GET /state` (snapshot), `WS /events` (push en vivo).
   - Reusar mDNS ([agent_discovery.dart](../lib/core/printing/agent_discovery.dart)) para descubrimiento + TXT con `business_id` y rol `hub`.
2. **Cliente Hub en el terminal:** capa que, en modo Hub, enruta `enqueueAction` al Hub LAN en vez de a Supabase, y se suscribe a `WS /events`.
3. **KDS offline (G1):** `kds_viewmodel`/`kitchen_repository` consumen el `WS /events` del Hub cuando no hay internet (en vez del Realtime de Supabase). Cache local de órdenes activas en el device KDS para arranque instantáneo. Cambios de estado (preparando/listo) se publican al Hub.
4. **Consistencia multi-terminal (G11):** el Hub serializa las ops de todos los terminales (FIFO con `received_at`), resuelve colisiones por LWW + reglas (item borrado, etc.) y reparte el estado consolidado por `WS`. **Esto habilita la carga de cualquier mesa sin red:** abrir una mesa que fue abierta/editada en OTRO terminal lee su orden e items desde el Hub (hoy `fn_open_table_and_load` es un RPC directo sin fallback — ver §6.4 del estado). El grid de productos para venta ya carga offline desde el snapshot del catálogo y no requiere Hub.
5. **Failover de Hub:** elección de líder simple (menor device_id presente, o configurado). Si el Hub cae, otro device asume y reanuda desde su SQLite replicado.
6. **Drenado Hub→Supabase:** al reconectar, el Hub replica su outbox a Supabase con la misma idempotencia, baja cambios y reconcilia.

**Server/migración:** constraint único por `op_id` en las tablas destino (órdenes, items, pagos) para idempotencia de extremo a extremo; RPC de ingestión por lote desde el Hub.

**Riesgos:** es esencialmente un mini-backend en LAN. Concurrencia, failover y *split-brain* (dos hubs) son los puntos finos. Mitigar con líder único por mDNS y *fencing token*.

**Aceptación:** apagar internet del local; dos cajas toman items de la misma mesa y ambas ven el estado consistente; la pantalla de cocina (tercer device) recibe las comandas en vivo; al reconectar, todo aparece en Supabase sin duplicados.

---

### F4 — NCF offline por rangos de dispositivo (G2)

**Objetivo:** emitir comprobante fiscal con NCF en el acto, sin red. **Depende de F0 (paquete) y F3 (Hub asigna).**

**Diseño:**
- **Partición de secuencia:** la secuencia del negocio ([ncf_sequences](../supabase/schema.sql) `:2946`) se divide en **sub-rangos asignados** (a device o al Hub). Tabla nueva `ncf_device_ranges(business_id, device_id, ncf_type, range_start, range_end, current, assigned_at, consumed_reported_at)`.
- **Asignación:** al aprovisionar (F0) o vía Hub, el terminal recibe un rango (p. ej. 5.000 números). El **Hub** es quien asigna localmente para evitar colisión entre terminales del mismo local.
- **Emisión offline:** `generate_ncf` local consume del rango del device/Hub. El comprobante se imprime con NCF real.
- **Reconciliación:** al reconectar, se reportan los NCF consumidos a Supabase; se concilian rangos, se detectan huecos y se reabastece el rango si se está agotando.
- **Agotamiento offline:** alerta temprana (al 80% del rango) y política definida si se agota sin red (bloquear cobro fiscal vs. recibo provisional — **lo decide el cliente**).

**Server/migración:** RPCs `fn_assign_ncf_range`, `fn_reconcile_ncf_consumption`; trigger de emisión adaptado para aceptar NCF pre-asignado offline.

**Riesgos (los serios):** **debe firmarse con el contador/DGII del cliente.** Huecos de numeración y rangos sin usar son observables fiscales. Documentar la política de huecos y exhaustión.

**Aceptación:** cobrar offline en dos terminales distintos → NCF únicos, sin colisión, conciliados al reconectar; alerta al 80% de rango.

---

### F5 — Reportes y tickets offline (G5)

**Objetivo:** consultar reportes del día e historial reciente sin red.

**Diseño:**
- **Agregación local:** el Hub (o el device en modo Solo) computa los reportes del día desde su SQLite autoritativo — los mismos desgloses que hoy hace `get_sales_summary_v2`, pero localmente sobre los datos del día.
- **Historial de tickets:** cache de los últimos N días de comprobantes en local para reimpresión/consulta.
- **Disclaimer de frescura:** la UI marca "datos locales del día" cuando no hay red.
- **Reportes históricos largos** (meses): siguen requiriendo red (no tiene sentido replicar meses en cada device). Esto **se documenta como límite aceptado** — no es un gap operativo del local.

**Aceptación:** sin red, ver ventas del día por categoría/área/empleado y reimprimir un ticket de hoy.

---

### F6 — Sync bidireccional y endurecimiento final (G15)

**Objetivo:** que cambios hechos en el server (otro local, backoffice) bajen al device, y cerrar bordes.

**Diseño:**
- **Pull incremental:** al reconectar y periódicamente, bajar deltas de catálogo, roster, config y secuencias (por `updated_at`/versión).
- **Resolución device↔server:** LWW por entidad con timestamp server para datos de catálogo/config; las transacciones del device siempre ganan (son hechos consumados).
- **Auditoría completa de reconciliación:** log visible de qué se subió, qué bajó, qué entró en conflicto.

**Aceptación:** cambiar un precio en backoffice → el device lo refleja tras reconectar sin perder ventas offline en vuelo.

---

## 4. Cambios server / migraciones (resumen)

| Necesidad | Fase | Objeto |
|---|---|---|
| Paquete de activación firmado | F0 | `fn_generate_activation_package` |
| Idempotencia extremo a extremo | F1/F3 | constraint único `op_id` en órdenes/items/pagos; RPC ingestión por lote |
| Rangos NCF por device | F4 | tabla `ncf_device_ranges` + `fn_assign_ncf_range` + `fn_reconcile_ncf_consumption` |
| Reabastecimiento/huecos NCF | F4 | reportes de consumo + detección de huecos |
| Pull incremental | F6 | endpoints/RPC de deltas por `updated_at` |

> Todas las migraciones se entregan **sin aplicar** (archivo + ROLLBACK) para que las revises antes de tocar producción, igual que las del reporte por área.

---

## 5. Matriz de cierre de gaps (estado objetivo)

| Feature | Hoy | Tras roadmap |
|---|---|---|
| Ventas / split bill | ✅ | ✅ (+ consistencia multi-terminal vía Hub) |
| Caja abrir/cerrar | ✅ encola | ✅ |
| **Movimientos de caja** | ❌ | ✅ (F2) |
| Pagos | ✅ encola | ✅ |
| **NCF / fiscal** | ❌ | ✅ rangos por device (F4) |
| Catálogo | ✅ (con snapshot) | ✅ (+ arranque en frío F0) |
| Inventario | ⚠️ | ✅ |
| **KDS pantalla** | ❌ | ✅ vía Hub LAN (F3) |
| KDS ticket impreso | ✅ | ✅ |
| **Impresión cola offline** | ⚠️ no drena | ✅ (F2) |
| **Reportes del día** | ❌ | ✅ local (F5) |
| Reportes históricos largos | ❌ | ⚠️ requieren red *(límite documentado)* |
| **Arranque en frío** | ❌ | ✅ paquete de activación (F0) |
| **Multi-terminal offline** | ❌ | ✅ Hub (F3) |
| Seguridad datos locales | ⚠️ texto plano | ✅ cifrado + limpieza (F1) |

**Único residual consciente:** reportes históricos de rango largo siguen pidiendo red (no es un gap del local; replicar meses por device no aporta).

---

## 6. Orden sugerido de ejecución

```
F0  Aprovisionamiento sin red        ──┐ (desbloquea todo lo demás)
F1  Endurecimiento núcleo            ──┤ (seguridad + mantenibilidad, sin Hub)
F2  Acciones offline faltantes       ──┘ (caja/impresión/void)
F3  Hub Local + KDS + multi-terminal ──┐ (la pieza grande)
F4  NCF por rangos                   ──┘ (depende del Hub)
F5  Reportes/tickets offline del día
F6  Sync bidireccional + cierre
```

F1 y F2 dan valor inmediato y bajo riesgo y **pueden empezar ya**. F3 es el grueso del esfuerzo. F4 no debe arrancar sin la firma fiscal del cliente.

---

## 7. Próximos pasos inmediatos

1. **Validar el residual y los riesgos del §0** contigo (en especial NCF/DGII y la realidad del "arranque en frío").
2. Si OK, **arrancar F1** (endurecimiento) que es seguro y no depende de decisiones externas, en paralelo a conseguir la firma fiscal para F4.
3. Por cada fase: PRD de detalle + migraciones sin aplicar + implementación incremental con `flutter analyze`/tests verdes.

---

*Documento de planificación basado en el código real al 2026-05-31. Las decisiones de KDS-LAN, NCF-por-rangos y arranque-sin-provisioning fueron tomadas por el dueño del producto; los riesgos del §0 quedan registrados para decisión informada.*
