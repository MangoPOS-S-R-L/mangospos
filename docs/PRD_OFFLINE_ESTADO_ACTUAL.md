# PRD — Estado Actual del Modo Offline de MangoPOS

> **Tipo de documento:** PRD de estado (as-built). Describe **lo que existe hoy**, no lo que se desea construir.
> **Fecha:** 2026-05-31
> **Alcance:** Toda la app `mangospos` (Flutter POS multiplataforma sobre Supabase).
> **Fuente:** Lectura directa del código. Cada afirmación cita `archivo:línea`.
> **Audiencia:** Producto, ingeniería, QA, soporte.

---

## 1. Resumen ejecutivo

MangoPOS tiene una **infraestructura offline sustancialmente implementada y en producción** (referida internamente como "Fase 6"). El núcleo —detección de conectividad, cola de operaciones persistente, motor de sincronización FIFO con reintentos, idempotencia y resolución básica de conflictos— está completo y es robusto para el flujo crítico de un POS: **tomar comandas, cobrar y cerrar caja sin internet**, y reconciliar al reconectar.

La cobertura offline **no es uniforme entre features**. El flujo de venta (órdenes, items, split bill, pagos) es offline-total con encolado optimista. La caja abre/cierra offline y el cierre a ciegas + impresión es 100% local. En contraste, **KDS, reportes, facturación fiscal (NCF) y movimientos de caja requieren conexión**, y la **cola de impresión offline se guarda pero no se drena**.

**Veredicto:** el offline es apto para operar el frente de caja sin red, con degradaciones conocidas en cocina (KDS), fiscal e impresión escalada.

---

## 2. Glosario

| Término | Significado |
|---|---|
| **Outbox / cola** | Lista persistente de mutaciones pendientes de enviar al server. |
| **Replay** | Re-ejecutar una acción encolada contra Supabase al reconectar. |
| **Idempotencia** | Garantía de que aplicar la misma op dos veces no duplica efectos. |
| **Fingerprint** | Hash determinístico del payload para detectar re-enques semánticamente idénticos. |
| **LWW** | *Last-Write-Wins*: ante conflicto, gana la última escritura. |
| **Snapshot** | Copia local serializada (JSON) del estado de una orden/recurso. |
| **Mapping local→remoto** | Tabla que traduce IDs generados en cliente (`local-order-X`) a UUIDs reales del server tras sincronizar. |

---

## 3. Arquitectura general

### 3.1 Capas

```
┌──────────────────────────────────────────────────────────┐
│ UI / ViewModels (Riverpod)                               │
│   sales_viewmodel, cashier_viewmodel, payment_viewmodel… │
└───────────────┬──────────────────────────────────────────┘
                │ consulta ConnectivityService.isConnected
                │ encola vía OfflinePosService.enqueueAction
                ▼
┌──────────────────────────────────────────────────────────┐
│ Núcleo Offline (lib/core/offline/)                       │
│   OfflinePosService  → cola, sync, replay, conflictos     │
│   OfflineCatalogService / InventoryOfflineCache /         │
│   ZonesOfflineCache   → snapshots de solo-lectura         │
│   storage/ (Drift)    → QueueActions, CompletedOps, FPs   │
└───────────────┬──────────────────────────────────────────┘
                │
        ┌───────┴────────┐
        ▼                ▼
┌────────────────┐  ┌────────────────────────────────────┐
│ Persistencia   │  │ Red                                 │
│  Drift/SQLite  │  │  ConnectivityService (adapter+probe)│
│  SharedPrefs   │  │  database_operation_wrapper (retry) │
│  SecureStorage │  │  Supabase client / RPC              │
└────────────────┘  └────────────────────────────────────┘
```

### 3.2 Bootstrap (`lib/main.dart`)

Orden de arranque ([lib/main.dart](../lib/main.dart)):

1. WidgetsBinding + handlers de error globales.
2. Purga de `shared_preferences.json` corrupto (regenera vacío).
3. **`Supabase.initialize()` — camino crítico, bloquea (timeout 20s).** Si falla, `StartupFailureApp`.
4. `runApp()` monta la UI de inmediato.
5. Post-frame → `_initializeBackgroundServices()`:
   - Auto-updater / Printer Agent / descubrimiento mDNS.
   - **`CacheManager.initialize()`** → instancia `StorageService` (SharedPreferences) + `ConnectivityService.initialize()` (chequeo de adapter, probe inicial, polling).

Dependencias: `SharedPreferences → Supabase → CacheManager → ConnectivityService`. La base Drift de la cola **no** se abre en el arranque; se abre *lazy* en el primer acceso (`OfflinePosService`, ~`lib/core/offline/offline_pos_service.dart:128`).

> **Implicación de producto:** el **primer arranque exige red** (Supabase init es bloqueante). Una vez con sesión, los reinicios sobreviven sin red mientras el token no expire (ver §6.1).

---

## 4. Detección de conectividad

**Archivo:** [lib/core/network/connectivity_service.dart](../lib/core/network/connectivity_service.dart) — **Implementado y funcional.**

- **Señal dual:** estado del adaptador (`connectivity_plus`) **Y** *reachability probe* HTTP contra Supabase (`/auth/v1/health`, `/rest/v1/`, `/`).
- **`isConnected = _adapterUp && _reachable`** (`:115`). Resuelve el caso "WiFi conectado pero sin WAN": el probe baja `isConnected` a `false` automáticamente.
- **Probe robusto:** acepta cualquier HTTP < 500 como "alcanzable" (un 401/404 prueba que la red llegó al server); solo timeouts/errores de red/5xx cuentan como caída. Timeout global 8s.
- **Umbral de fallos:** `_failureThreshold = 2` (`:72`) — tolera 2 fallos consecutivos antes de marcar offline (anti-falsos-positivos).
- **Polling adaptativo:** 30s cuando online (`_probeInterval`, `:75`), 5s cuando offline (`_probeIntervalFast`, `:81`) para recuperación rápida.
- **Diagnóstico:** `ConnectivityDiagnostics` expone `adapterUp`, `reachable`, `failedProbes`, `lastProbeAt/Url/Status/Error/Duration` para un diálogo de soporte (`connectivity_diagnostics_dialog.dart`).
- **Testing:** `simulateDisconnect()` / `simulateReconnect()` (`:334`, `:343`).
- **Consumidores:** `connectionStream` (Stream<bool>) lo escuchan `sales_viewmodel`, `offline_auth_service` e `inventory_repository`.

---

## 5. Núcleo offline: cola, sincronización, conflictos, reintentos

**Archivo principal:** [lib/core/offline/offline_pos_service.dart](../lib/core/offline/offline_pos_service.dart)

### 5.1 Persistencia de la cola (backend dual)

| Plataforma | Backend | Detalle |
|---|---|---|
| **Nativo** (Win/macOS/Linux/Android/iOS) | **Drift/SQLite** | BD `mangopos_offline_queue.db`. Tablas `QueueActions`, `CompletedOps`, `CompletedFingerprints` ([storage/offline_queue_db.dart](../lib/core/offline/storage/offline_queue_db.dart)). Schema v1, sin migraciones aún. |
| **Web** | **SharedPreferences** | Drift requiere `dart:ffi` (no existe en JS). Guard `kIsWeb` (`:128`). Reescribe la lista JSON entera por operación (O(n)). |

- **Migración automática SP→Drift** (`:140`): la primera vez por negocio importa la cola legacy de SharedPreferences a SQLite y borra las keys viejas. Idempotente; si falla, los datos quedan en SP (no se pierden).
- **Motivación documentada de Drift:** con 500+ items, SP reescribía toda la lista en cada enqueue (O(n)); SQLite indexado es O(log n) ([storage/offline_queue_db.dart:3-22](../lib/core/offline/storage/offline_queue_db.dart)).
- **El resto del cache (snapshots, mappings, catálogo, inventario) sigue en SharedPreferences** a propósito: writes infrecuentes y pequeños.

**Tabla `QueueActions`:** `id` (PK uuid), `businessId`, `type`, `payloadJson`, `status` (pending/processing/completed/failed), `attempts`, `queuedAt`, `completedAt`, `fingerprint`, `lastError`, `nextRetryAt`, `processingStartedAt`.

**Keys de SharedPreferences relevantes:**
```
offline_queue_{businessId}                  offline_completed_ops_{businessId}
offline_completed_fingerprints_{businessId} offline_snapshot_{businessId}_{slotId}
offline_order_map_{businessId}              offline_item_map_{businessId}
offline_cash_session_map_{businessId}       offline_print_queue_{businessId}
```

### 5.2 Encolado

`enqueueAction(businessId, action)` (`:332`): lee cola → anota `device_id` de origen (auditoría LWW) → normaliza (genera uuid, `queued_at`, fingerprint) → **compacta** → persiste.

**Compactación** (`:723`): fusiona/cancela ops redundantes del mismo item/orden antes de sincronizar. Ej.: `add_item` + `delete_item` del mismo item temporal → ambas se eliminan; `add_item` + `update_quantity` → se fusiona la qty en el add. No toca ops ya completadas.

**Fingerprint** (`:698`): `type|order_id|item_id|menu_item_id|product_id|check_pos|qty|takeout|notes`. Detecta re-enques tras crash/reintento de UI con `id` distinto pero payload idéntico.

### 5.3 IDs generados en cliente

`offline-op-{uuid}` (acción), `local-order-{uuid}` (orden), `tmp_{uuid}` (item), `local-cash-session-{uuid}` (sesión de caja). Todos UUID v4.

### 5.4 Motor de sincronización (`syncPendingActions`, `:380`)

- **Triggers:** (a) **reconexión** — `sales_viewmodel` escucha `connectionStream` y dispara sync al pasar `false→true`; (b) **manual** (botón en shell). **No hay sync periódico por tiempo.**
- **Orden:** **FIFO estricto** por `queuedAt`, por dependencias causales (abrir caja antes de cerrar; crear orden antes de agregar items).
- **Loop por acción:** skip si completada o ya marcada en `CompletedOps`/`CompletedFingerprints` (idempotencia) → skip si no llegó su `next_retry_at` (backoff) → marca `processing` → `_replayAction` → en éxito marca `completed` + registra idempotencia → al final **prune** de completadas viejas.
- **Resultado:** `OfflineQueueSyncResult { processed, completed, failed, skipped, pending, conflicts[] }` → alimenta el badge y el snackbar del shell.

### 5.5 Operaciones soportadas en replay (`_replayAction`, switch en `:841`)

15 tipos verificados:

| # | Tipo | Dominio | Notas |
|---|---|---|---|
| 1 | `open_cash_session` | Caja | crea mapping local→remoto |
| 2 | `close_cash_session` | Caja | resuelve session_id vía mapping; tolera "ya cerrada" |
| 3 | `inventory_adjust` | Inventario | LWW server-side (`FOR UPDATE` sobre stock) |
| 4 | `inventory_movement` | Inventario | delta de stock |
| 5 | `add_item` | Orden | re-aplica modifiers; mapea `tmp_`→uuid |
| 6 | `delete_item` | Orden | item ausente = idempotente (OK) |
| 7 | `update_item_quantity` | Orden | item ausente → conflicto |
| 8 | `update_item_notes` | Orden | item ausente → conflicto |
| 9 | `toggle_item_takeout` | Orden | item ausente → conflicto |
| 10 | `move_item_to_check` | Orden/Split | item ausente → conflicto |
| 11 | `mark_order_takeout` | Orden | — |
| 12 | `void_order` | Orden | **razón de auditoría NO se persiste (limitación v1)** |
| 13 | `send_to_kitchen` | Cocina | vía `PrintingService` |
| 14 | `confirm_local_order` | Cocina | vía `PrintingService` |
| 15 | `process_payment` | Pago | preserva `paid_at` original (offline) vía RPC |

Cualquier otro tipo → `UnsupportedError` (caso `default`).

### 5.6 Resolución de conflictos — **parcial**

- **Item borrado por otro terminal** (`_isItemMissingError`, `:90`; detecta `pgrst116`, `no rows`, `not found`): `delete_item` lo trata como éxito (estado deseado ya cumplido); los `update_*`/`move` lanzan `_OfflineSyncSkip` → se marcan completadas + se **reporta conflicto** al cajero.
- **Modifiers que ya no aplican** (cambiaron de precio/desaparecieron): no aborta; reporta conflicto ("revisa el total").
- **Sesión de caja ya cerrada:** se captura y completa en silencio.
- **Resolución de IDs locales** (`:1264`): si la acción referencia `local-order-X`/`tmp_X` y no existe el mapping, **recrea la orden** o **busca el item** por `product_id`+`notes`+`takeout` (fallback: último item agregado).
- **Estrategia global:** **LWW**, sin *merge* de datos en conflicto. Los conflictos se **reportan**, no se auto-resuelven más allá de lo anterior.

### 5.7 Reintentos y errores

- **Backoff escalonado** (`_retryDelaySeconds`, `:824`): **3s → 8s → 15s → 30s** (a partir del 4º intento).
- **Errores de conectividad** (`_isConnectivityError`, `:104`: socket/timeout/handshake/host lookup…): **rompen el loop** (el resto fallaría igual) y reintentan luego.
- **Errores de negocio** (constraint/validación): marcan `failed`, backoff, reintento en próximo sync.
- **Sin hard-limit de intentos:** una acción con error permanente (constraint incumplible) **queda en `failed` para siempre** hasta limpieza manual.
- **Dead-letter / limpieza:** botón "Limpiar cola" en el shell → `clearPendingActions()` borra pendientes+fallidas pero **no** toca los markers de idempotencia (evita re-aplicar lo que sí llegó).
- **Wrapper de red** ([database_operation_wrapper.dart](../lib/core/network/database_operation_wrapper.dart)): backoff con jitter, timeouts (30s read / 60s write / 120s RPC), máx 3 reintentos, solo sobre errores recuperables.

---

## 6. Almacenamiento local y cache

### 6.1 Autenticación offline — **Implementado**

**Archivo:** [lib/core/auth/offline_auth_service.dart](../lib/core/auth/offline_auth_service.dart)

- **Device binding revocable** en `FlutterSecureStorage` (Keychain iOS / EncryptedSharedPreferences Android): `mp_offline_device_token`, `mp_offline_device_id`, `mp_offline_device_business`. Solo owner/admin puede `bindDevice()` (RPC `fn_device_bind`).
- **Roster de usuarios** (SharedPreferences, `mp_offline_roster_{businessId}`): `user_id`, `name`, **`pin_hash` (bcrypt server-side)**, `role`, `permissions`, `is_active`.
- **Login por PIN offline:** `verifyPin()` valida bcrypt **localmente, sin server**.
- **TTL del roster = 24h** (`rosterTtl`, `:112`). Si vence (`isRosterStale`), se **bloquean logins offline** y se fuerza reconexión (protege contra empleados dados de baja).
- **Background sync del roster:** inmediato + `Timer.periodic` cada **1h** (`_periodicSyncInterval`, `:329`) + re-sync al reconectar.
- **Recuperación de sesión Supabase sin red:** si el access token expira sin red, `_scheduleExpiredAuthRecovery` (en `main.dart`) reintenta el refresh con backoff (2s→8s→15s→30s, máx 3) y conserva el refresh_token esperando reconexión.

> **Regla de producto:** **no se puede iniciar sesión por primera vez sin red** (Supabase init bloqueante). Con device vinculado + roster fresco, **el login por PIN opera offline**.

### 6.2 Catálogo (productos/menú) — **Implementado, solo-lectura**

[lib/core/offline/offline_catalog_service.dart](../lib/core/offline/offline_catalog_service.dart). Key `offline_catalog_{businessId}` (JSON): categorías, menús, productos, `menu_products`, favoritos, `last_product_updated_at`, `product_count`. Búsqueda/filtros/favoritos 100% locales. TTL de referencia: 12h. **Sin snapshot y sin red → menú vacío** (no se pueden agregar items). Modifiers/combos se cachean en memoria en `sales_viewmodel` (primer tap paga red, luego instantáneo).

> **Carga de productos para venta (verificado):** el grid de venta SÍ cae al catálogo offline al cargar, no solo lo guarda. [menu_browser_viewmodel.dart:352-367](../lib/presentation/sales/viewmodel/menu_browser_viewmodel.dart): carga el snapshot, y si `!isConnected && hayDatosLocales` o si la query falla (`catch`), pinta el catálogo cacheado. Categorías, productos y búsqueda operan sin red.

### 6.3 Inventario — **Implementado, mutable optimista**

[lib/core/offline/inventory_offline_cache.dart](../lib/core/offline/inventory_offline_cache.dart). Key `offline_inventory_snapshot_{businessId}_{warehouseId}`: items + stock. Lectura con fallback a cache (la UI puede marcar "datos desactualizados"). `setStock` / `applyStockDelta` permiten ajustes offline; el server reconcilia con LWW al sincronizar (`inventory_adjust`/`inventory_movement`).

### 6.4 Zonas/mesas — **Implementado, solo-lectura**

[lib/core/offline/zones_offline_cache.dart](../lib/core/offline/zones_offline_cache.dart). Keys `offline_zones_snapshot_{businessId}` y `offline_zone_status_snapshot_{zoneId}`. Fallback *stale* para pintar mesas si la API falla.

> **Carga de mesas (verificado) — y su límite:**
> - **Grilla de mesas/zonas (ver el salón):** ✅ offline. [zones_repository.dart:66-81](../lib/data/repositories/zones_repository.dart) devuelve `fromCache: true` desde `ZonesOfflineCache` cuando la red falla; el estado de cada mesa (`TableStatus`) igual (`:559-573`).
> - **Abrir UNA mesa y traer su orden/items:** ⚠️ usa `fn_open_table_and_load` ([sales_repository.dart:356](../lib/data/repositories/sales_repository.dart)), RPC directo **sin fallback offline propio**. Funciona sin red **solo si la orden ya está en el snapshot local de este device** (mesa que este equipo abrió/editó). **Una mesa abierta en otro terminal no se puede cargar sin red** en el modo actual — lo resuelve el Hub Local (ver gap G11 y F3 del roadmap).

### 6.5 Órdenes activas (snapshots) — **Implementado, mutable**

`offline_snapshot_{businessId}_{slotId}` (JSON de `CurrentOrderState`: order + items + checks + origen + timestamp). Se guarda tras cada cambio → **sobrevive a crashes**. Al cargar, remapea IDs locales→remotos. Se borra al cerrar/pagar la orden.

### 6.6 Cache global / `CacheManager` — **Día 1 (básico)**

[lib/core/cache/cache_manager.dart](../lib/core/cache/cache_manager.dart) + [cache_config.dart](../lib/core/cache/cache_config.dart). Módulos con prioridad/estrategia/TTL/maxSize (productos 12h, ventas 1h, caja 1d, mesas 5m, config 24h, clientes 12h, inventario 6h; **reportes y fidelización deshabilitados**). Límite global 30MB.

- **Versionado:** `system_cache_version` (=1) + `system_app_version`. En instalación nueva / update / cambio de versión → **limpia todo el cache** preservando auth. **Downgrade pierde la cola** (forward-only).
- **Encolado propio del CacheManager: NO implementado** → `// TODO DÍA 3: Agregar a queue si queueIfOffline = true` (`:482`). *La cola real vive en `OfflinePosService`, no aquí.* La compresión y el *enforcement* de tamaño están configurados pero **no aplicados** (solo se mide).

### 6.7 Seguridad y multi-tenant

- **Cifrado:** solo tokens de device en SecureStorage. **PIN hashes, órdenes, inventario y catálogo van en SharedPreferences en texto plano** (JSON). Riesgo: un device comprometido expone el histórico offline.
- **Scoping:** todas las keys llevan `{businessId}`. **No hay limpieza automática al logout ni al cambiar de negocio** → snapshots/cola/catálogo del negocio anterior permanecen en disco. `clearDeviceBinding()` borra el token pero deja datos `offline_*`.

---

## 7. Matriz de cobertura offline por feature

| Feature | ¿Offline? | Comportamiento | Evidencia |
|---|---|---|---|
| **Auth — primer login** | ❌ Requiere red | Supabase init bloqueante | `main.dart` |
| **Auth — sesión existente** | ⚠️ Parcial | Refresh con reintentos; espera reconexión | `main.dart`, `offline_auth_service.dart` |
| **Auth — PIN (roster)** | ✅ Total | bcrypt local, TTL 24h | `offline_auth_service.dart:259` |
| **Ventas — abrir mesa/crear orden** | ✅ Total | ID local + snapshot | `offline_pos_service.dart:290` |
| **Ventas — agregar/borrar/editar items** | ✅ Total | optimista + cola + compactación | `sales_viewmodel.dart`, `…service.dart:943` |
| **Ventas — transferir mesa** | ✅ Total | encolado | `…service.dart:1119` |
| **Split bill — checks / mover / cobrar** | ✅ Total | todo encolado | `…service.dart:1119,1213` |
| **Caja — abrir/cerrar** | ✅ Encola | ID local + resolución de sesión | `…service.dart:842,867` |
| **Caja — cierre a ciegas + impresión** | ✅ Total local | sin tocar Supabase | `CashClosePrintService` |
| **Caja — movimientos de efectivo** | ❌ Requiere red | RPC directo, **sin encolado** | `cashier_repository.dart:553-573` |
| **Pagos — registrar cobro** | ✅ Encola | preserva `paid_at` | `…service.dart:1213` |
| **Pagos — NCF / fiscal** | ❌ Requiere red | NCF se genera solo en sync | (lógica fiscal server-side) |
| **Catálogo — navegar/buscar/favoritos** | ✅ Total | snapshot local | `offline_catalog_service.dart` |
| **Catálogo — sin snapshot previo** | ❌ Bloquea | menú vacío | — |
| **Inventario — leer** | ⚠️ Cache stale | fallback con disclaimer | `inventory_repository.dart` |
| **Inventario — ajustar/mover** | ✅ Encola | LWW en server | `…service.dart:910,929` |
| **KDS — ver órdenes** | ⚠️ Solo polling | refresco 30s; **falla sin red** | `kds_viewmodel.dart` |
| **KDS — realtime** | ❌ No | WebSocket no conecta | `kds_viewmodel.dart` |
| **KDS — cambiar estado (preparando/listo)** | ❌ Requiere red | RPC directo, **sin cola** | `kds_viewmodel.dart` |
| **Impresión — USB/LAN/BLE/Agent local** | ✅ Total | localhost / LAN, sin internet | `lib/core/printing/`, `agent/` |
| **Impresión — cola offline** | ⚠️ Se guarda, **no se drena** | `enqueuePrintJob` escribe SP; **sin lector en sync** | `…service.dart:349` |
| **Impresión — escalado a cloud** | ❌ Requiere red | — | — |
| **Reportes / analytics** | ❌ Requiere red | queries directas, sin cache | `lib/presentation/reports/` |
| **Tickets/billing — historial** | ❌ Requiere red | lectura directa | `lib/presentation/tickets_billing/` |
| **Tickets/billing — recibo en cobro** | ✅ Local | PDF/impresión local | — |

Leyenda: ✅ funciona offline · ⚠️ parcial/degradado · ❌ requiere conexión.

---

## 8. Estado de madurez

### ✅ Implementado y en producción
Detección de conectividad dual · cola persistente (Drift nativo + SP web) con migración automática · normalización/compactación/fingerprint · sync FIFO con replay de 15 tipos de acción · idempotencia (ops + fingerprints) · backoff escalonado · clasificación de errores · resolución de conflictos por LWW + reporte · mappings local→remoto · snapshots de órdenes · auth por PIN offline con roster TTL · caches de catálogo/inventario/zonas · UI (badge de pendientes, snackbar post-sync, botón limpiar cola, diálogo de diagnóstico) · wrapper de reintentos de red.

### ⚠️ Parcial / con limitaciones (v1)
- **`void_order`**: la razón de auditoría no se persiste en server (`…service.dart:1164`).
- **Acciones con error permanente**: quedan en `failed` indefinidamente (sin dead-letter automático).
- **`CacheManager` queue propio**: stub (`TODO DÍA 3`); compresión y *enforcement* de tamaño no aplicados.
- **Web**: cola en SP es O(n) (aceptable como caso secundario).
- **Drift schema v1**: sin migraciones (forward-only; downgrade pierde cola).
- **Multi-negocio en un device**: bound a 1 negocio; no hay rebind ni limpieza al cambiar.

### ❌ No implementado
- **Sync periódico por tiempo** (solo reconexión/manual).
- **KDS offline** (ni cache de órdenes nuevas, ni cola de cambios de estado, ni realtime).
- **Movimientos de caja offline** (depósitos/retiros/gastos).
- **Facturación fiscal (NCF) offline**.
- **Drenado de la cola de impresión offline** (`offline_print_queue_*` se llena pero nadie la consume).
- **Reportes/tickets offline** (sin cache de lectura).
- **Sync bidireccional** (cambios del server no bajan al device en background salvo refresh manual/realtime puntual).
- **Limpieza de datos offline al logout / cambio de negocio**.

---

## 9. Riesgos y consideraciones de producto

| # | Riesgo | Impacto | Mitigación actual / sugerida |
|---|---|---|---|
| R1 | **KDS ciego sin red** | La cocina no ve comandas nuevas; el camarero las toma pero no se despachan | Hoy: ninguna. Sugerido: cache de órdenes activas + cola de cambios de estado |
| R2 | **NCF no se emite offline** | Cobros sin comprobante fiscal hasta sync | Hoy: el pago se encola y el NCF se genera al reconectar; comunicar la espera |
| R3 | **Cola de impresión offline no se drena** | Tickets encolados que nunca salen | Sugerido: drenar `offline_print_queue_*` en sync o eliminar la API si no se usa |
| R4 | **Movimientos de caja sin offline** | Depósitos/retiros se pierden sin red | Sugerido: encolar `cash_transaction` (estructura ya prevista) |
| R5 | **Datos offline en texto plano + sin limpieza al logout** | Usuario B ve histórico offline de A | Sugerido: `clearAllOfflineData()` en logout; valorar cifrado de snapshots |
| R6 | **Acciones `failed` permanentes** | Cola crece y el badge nunca baja | Sugerido: dead-letter con tope de intentos + visor de fallidas |
| R7 | **Downgrade pierde la cola** | Pérdida de ventas no sincronizadas | Documentar en release notes; bloquear downgrade con cola pendiente |
| R8 | **Sin sync periódico** | Si nadie toca la app tras reconectar y el stream no dispara, la cola espera | Sugerido: timer de sync de respaldo cuando hay pendientes |
| R9 | **Doble cobro por race** | Fingerprint dedup no cubre timestamp local vs server | Validar idempotencia de pago server-side por (orden, monto, método) |

---

## 10. Apéndice — Inventario de archivos

| Área | Archivo |
|---|---|
| Conectividad | [lib/core/network/connectivity_service.dart](../lib/core/network/connectivity_service.dart) |
| Reintentos de red | [lib/core/network/database_operation_wrapper.dart](../lib/core/network/database_operation_wrapper.dart) |
| Servicio offline núcleo | [lib/core/offline/offline_pos_service.dart](../lib/core/offline/offline_pos_service.dart) |
| Cola Drift (schema/DAO) | [lib/core/offline/storage/offline_queue_db.dart](../lib/core/offline/storage/offline_queue_db.dart), [offline_queue_dao.dart](../lib/core/offline/storage/offline_queue_dao.dart) |
| Catálogo offline | [lib/core/offline/offline_catalog_service.dart](../lib/core/offline/offline_catalog_service.dart) |
| Inventario offline | [lib/core/offline/inventory_offline_cache.dart](../lib/core/offline/inventory_offline_cache.dart) |
| Zonas/mesas offline | [lib/core/offline/zones_offline_cache.dart](../lib/core/offline/zones_offline_cache.dart) |
| Auth offline | [lib/core/auth/offline_auth_service.dart](../lib/core/auth/offline_auth_service.dart) |
| Cache manager | [lib/core/cache/cache_manager.dart](../lib/core/cache/cache_manager.dart), [cache_config.dart](../lib/core/cache/cache_config.dart) |
| Storage wrapper | [lib/core/storage/storage_service.dart](../lib/core/storage/storage_service.dart) |
| Bootstrap | [lib/main.dart](../lib/main.dart) |
| Consumo (ventas) | [lib/presentation/sales/viewmodel/sales_viewmodel.dart](../lib/presentation/sales/viewmodel/sales_viewmodel.dart) |
| Consumo (caja) | [lib/data/repositories/cashier_repository.dart](../lib/data/repositories/cashier_repository.dart) |
| KDS | [lib/presentation/kds/viewmodel/kds_viewmodel.dart](../lib/presentation/kds/viewmodel/kds_viewmodel.dart) |
| Doc cierre de caja | [docs/README_CIERRE_CAJA_FLUTTER.md](README_CIERRE_CAJA_FLUTTER.md) |

---

*Documento generado a partir de lectura directa del código (2026-05-31). Refleja el estado al commit actual de la rama `main`. Trátese el código como fuente de verdad ante cualquier divergencia.*
