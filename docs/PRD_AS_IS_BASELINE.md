# PRD AS-IS — MangoPOS Baseline para Migración Offline-First

**Versión:** 1.0
**Fecha:** 2026-05-20
**Autor:** Auditoría arquitectónica
**Alcance:** Documentar exhaustivamente CÓMO FUNCIONA HOY MangoPOS respecto a conectividad, estado, autenticación y persistencia. **Este documento es AS-IS puro — no propone cambios, refactors ni soluciones.**
**Punto de partida para:** PRD subsecuente de migración a offline-first.

---

## Tabla de contenidos

1. [Resumen ejecutivo](#1-resumen-ejecutivo)
2. [Inventario de operaciones por dependencia de red](#2-inventario-de-operaciones-por-dependencia-de-red)
3. [Autenticación y sesión](#3-autenticación-y-sesión)
4. [Capa de datos](#4-capa-de-datos)
5. [Escrituras y consistencia](#5-escrituras-y-consistencia)
6. [Impresión](#6-impresión)
7. [Sesión de caja y multi-business](#7-sesión-de-caja-y-multi-business)
8. [Sincronización en tiempo real](#8-sincronización-en-tiempo-real)
9. [Infraestructura relevante para offline](#9-infraestructura-relevante-para-offline)
10. [Riesgos y brechas conocidas para offline](#10-riesgos-y-brechas-conocidas-para-offline)
11. [Apéndices](#11-apéndices)
12. [Preguntas abiertas](#12-preguntas-abiertas)

---

## 1. Resumen ejecutivo

### Una frase honesta

**Hoy MangoPOS es online-first con fallbacks limitados:** el catálogo de productos puede consultarse offline desde un snapshot local; algunas operaciones de edición de items (agregar/borrar/mover) se encolan localmente para sincronizar después; pero **el cobro, la apertura/cierre de caja, la emisión de NCF, la asignación de cliente, el envío a cocina con descuento de stock confirmado y los reportes Z** requieren conexión activa con Supabase. Si el internet se cae a mitad de un turno, el cajero puede seguir capturando ítems pero **no puede facturar**.

### Operaciones críticas vs dependencia de red

| Operación | Funciona offline | Notas |
|---|---|---|
| Login (primera vez) | ❌ No | Supabase Auth requiere red |
| Login (sesión persistida) | ⚠️ Parcial | JWT cacheado, pero al primer refresh-fail eventual logout |
| Consultar catálogo de productos | ✅ Sí | Snapshot local en SharedPreferences |
| Abrir mesa / abrir orden | ❌ No | RPC `fn_open_table` |
| Agregar/editar/borrar ítems | ⚠️ Encolado | Hay cola local en `OfflinePosService` para ops de items |
| Enviar a cocina | ⚠️ Parcial | La acción se puede encolar; el descuento de inventario solo ocurre online |
| Imprimir comanda (cocina) | ✅ Sí | TCP/USB/BT directos; cloud-queue como fallback |
| Cobrar | ❌ No | RPC `fn_process_payment_v3` no se encola |
| Generar NCF | ❌ No | Trigger post-pago en Supabase; no hay rangos pre-asignados al cliente |
| Imprimir factura | ✅ Sí (técnico) | El ESC/POS es local — pero requiere haber cobrado primero |
| Aplicar descuento | ❌ No (por permisos) | Permisos cached pero el descuento llama RPC |
| Aplicar cortesía | ❌ No | RPC `updateItemDiscountAndNotes` |
| Devolución / anulación | ❌ No | RPC; trigger `consume_inventory_from_order` reconcilia |
| Cerrar caja | ❌ No | RPC `fn_close_cash_session` |
| Ver órdenes activas (mesero) | ⚠️ Stale | Realtime no reconecta automáticamente |

---

## 2. Inventario de operaciones por dependencia de red

Tabla maestra. Cada fila cita el archivo Dart y, cuando aplica, el RPC SQL.

| # | Operación | Endpoint / Tabla / RPC | Crítica para venta | Comportamiento sin red | Archivo responsable |
|---|---|---|---|---|---|
| 1 | Login email+password | `auth.signInWithPassword()` (Supabase Auth / GoTrue) | Sí (entrada al sistema) | Login nuevo falla con TimeoutException; sesión previa persiste si el JWT en storage no expiró | [lib/presentation/auth/login/login_viewmodel.dart:38-93](lib/presentation/auth/login/login_viewmodel.dart) |
| 2 | Verificar OTP (post-signup) | `auth.verifyOTP()` | Sí | Falla sin red | login_viewmodel.dart:95-120 |
| 3 | Refresh de token | `auth.refreshSession()` automático (autoRefreshToken=true) | Sí (a largo plazo) | Reintenta 3 veces con backoff (2s, 4s, 8s); si todas fallan y aún hay refreshToken, preserva sesión local; sin refreshToken, logout local | [lib/main.dart:773-886](lib/main.dart) (`_scheduleExpiredAuthRecovery`) |
| 4 | Listar mis negocios | `SELECT user_businesses` | Sí (post-login) | Falla; se conserva el activeBusinessId previo en SessionState si existe | [lib/services/session/session_controller.dart:374-378](lib/services/session/session_controller.dart) |
| 5 | Activar business / cargar permisos | RPC `fn_user_effective_permissions(p_user_id, p_business_id)` | Sí | Fallback a presets de rol hard-coded en [access_control_catalog.dart](lib/core/security/access_control_catalog.dart) | session_controller.dart:770-832 |
| 6 | Abrir caja | RPC `fn_open_cash_session` | Sí | Falla; no se puede abrir caja sin red | [lib/data/repositories/cashier_repository.dart:65-94](lib/data/repositories/cashier_repository.dart) |
| 7 | Buscar sesión activa de caja | `SELECT cash_register_sessions` (con filtro por register / business) | Sí | Falla; pantalla muestra "Caja cerrada" | cashier_repository.dart:294-349 |
| 8 | Cerrar caja | RPC `fn_close_cash_session` | Sí | Falla. Variance check (`closeSessionWithVarianceCheck`) requiere red también | cashier_repository.dart:96-150 + [variance_confirm_dialog.dart:169-214](lib/presentation/cashier/widgets/variance_confirm_dialog.dart) |
| 9 | Conteo ciego firmado | `INSERT cash_count_blind` (directo, con trigger de inmutabilidad post-firma) | Sí | Falla. UNIQUE en `(session_id, attempt_number)`; máximo 2 conteos por sesión | cashier_repository.dart:159-183 |
| 10 | Reporte Z (resumen de cierre) | RPC `fn_get_cash_session_summary` | Sí | Falla; no se calcula el reporte | cashier_repository.dart:215-232 |
| 11 | Cargar catálogo (categorías + menús + productos) | `SELECT menu_items, categories, menu_item_links` | Sí | **Funciona con snapshot local** si fue sincronizado previamente. Sin snapshot: vista vacía | [lib/presentation/sales/viewmodel/menu_browser_viewmodel.dart:586-630](lib/presentation/sales/viewmodel/menu_browser_viewmodel.dart) + [lib/core/offline/offline_catalog_service.dart:152-226](lib/core/offline/offline_catalog_service.dart) |
| 12 | Abrir mesa | RPC `fn_open_table` (con `pg_advisory_xact_lock`) | Sí | Falla. La cola offline no encola `fn_open_table` | [lib/data/repositories/sales_repository.dart:286-307](lib/data/repositories/sales_repository.dart) |
| 13 | Abrir venta manual / quick | RPC `fn_open_manual_or_quick` | Sí | Falla | sales_repository.dart:318 |
| 14 | Agregar ítem (online directo) | RPC `fn_add_item_from_menu` | Sí | Falla. `OfflinePosService` encola la acción con `tmp_` id | sales_repository.dart:555 |
| 15 | Agregar ítem (offline encolado) | Local + cola en `OfflinePosService` | Sí | ✅ Funciona; INSERT diferido. Genera `tmp_<uuid>` para item_id | [lib/core/offline/offline_pos_service.dart:202-303](lib/core/offline/offline_pos_service.dart) |
| 16 | Actualizar cantidad de ítem | RPC `fn_update_item_qty` | Sí | Encolado en cola offline | sales_repository.dart + offline_pos_service.dart |
| 17 | Editar nota de ítem | RPC `fn_update_item_notes` | Medio | Encolado | sales_repository.dart |
| 18 | Cambiar takeout (in-place) | RPC `fn_toggle_item_takeout` | Sí | Encolado | sales_repository.dart |
| 19 | Borrar ítem | RPC `fn_delete_item` | Sí | Encolado. Si el item es `tmp_` y el add aún está en cola, se compacta | offline_pos_service.dart:353-438 |
| 20 | Mover ítem a otro check | RPC `fn_move_item_to_check` o `fn_move_items_to_check_batch` | Sí | Encolado | sales_repository.dart |
| 21 | Aplicar descuento a ítem | RPC `fn_update_item_discount` o `fn_update_item_discount_and_notes` | Sí | Falla (sin red); el descuento no se encola | sales_repository.dart |
| 22 | Aplicar cortesía a ítem | Mismo RPC de descuento, valor = total | Sí | Falla sin red | sales_viewmodel.dart:1679-1754 |
| 23 | Calcular impuestos | Local (Dart) + función SQL `fn_resolve_order_item_tax_profile` para el INSERT del item | Sí | El cálculo Dart funciona offline (`order_pricing_utils.dart`); el persisted `oi.tax`/`oi.subtotal` se calcula en backend al INSERT | [lib/data/utils/order_pricing_utils.dart](lib/data/utils/order_pricing_utils.dart) + [lib/core/tax/tax_engine.dart](lib/core/tax/tax_engine.dart) |
| 24 | Aplicar propina (servicio) | Server-side, vía tax_engine en SQL | Sí | El total con propina se calcula offline desde Dart como estimación; el oficial viene del backend | order_pricing_utils.dart + tax_engine.dart |
| 25 | Asignar cliente a check + NCF | RPC `fn_set_check_customer_and_ncf` | Sí (para factura fiscal) | Falla | sales_repository.dart:1170 |
| 26 | Enviar a cocina | RPC `fn_confirm_order_to_kitchen` + trigger `consume_inventory_from_order` | Sí | Acción `send_to_kitchen` se encola en `OfflinePosService`. El descuento de stock solo ocurre online | sales_repository.dart:1276-1285 |
| 27 | Cobrar (1 método) | RPC `fn_process_payment_v3` (atómico, idempotente con `split_sequence`) | **Sí (crítica)** | **No se encola; falla** | [lib/data/repositories/sales_repository_improved.dart:306-389](lib/data/repositories/sales_repository_improved.dart) |
| 28 | Cobrar (split bill / multi-método) | N llamadas a `fn_process_payment_v3` con `split_sequence` incremental | Sí | Falla sin red | sales_repository_improved.dart + [payment_split_viewmodel.dart:413+](lib/presentation/sales/viewmodel/payment_split_viewmodel.dart) |
| 29 | Crear sub-checks (split bill) | RPC `fn_create_split_bill`, `fn_split_items_equally`, `fn_explode_items_to_units` | Sí | Falla sin red | sales_repository.dart |
| 30 | Generar NCF | RPC `generate_ncf` (con `FOR UPDATE` en `ncf_sequences`) | Sí (fiscal) | Falla. Se ejecuta en trigger post-pago, no en cliente directamente | [supabase/migrations/20260426_0001_fix_ncf_collisions_and_trigger_idempotency.sql:211-272](supabase/migrations/20260426_0001_fix_ncf_collisions_and_trigger_idempotency.sql) |
| 31 | Crear fiscal_document | RPC `create_fiscal_document` (trigger automático en pago) | Sí (fiscal) | Falla | sales_repository.dart:1793 |
| 32 | Emitir e-CF a DGII (síncrono) | Edge function `emit-document` vía `_client.functions.invoke(...)` | Sí para fiscal electrónico | Falla; ticket sale como "Pendiente de emisión a DGII" hasta que cron de respaldo lo recupere | [lib/presentation/sales/view/table_order_screen.dart:1760-1780](lib/presentation/sales/view/table_order_screen.dart) (post-payment_split.dart) |
| 33 | Imprimir comanda (cocina) | ESC/POS local sobre TCP/USB/BT | Sí | ✅ Funciona offline (LAN directa). Solo falla escalada a cloud queue | [lib/data/repositories/printing_service.dart](lib/data/repositories/printing_service.dart) + [lib/services/printing/print_ticket_service.dart](lib/services/printing/print_ticket_service.dart) |
| 34 | Imprimir factura / recibo | Mismo ESC/POS local | Parcial | El ESC/POS imprime; pero requiere haber cobrado primero (#27) | printing_service.dart |
| 35 | Reimprimir factura | ESC/POS local + lectura de `fiscal_documents` | Medio | Falla la lectura del fd si no hay red | printing_service.dart `reprintInvoice` |
| 36 | Imprimir cierre de caja | ESC/POS local | Sí (al cerrar caja) | Si el cierre falló por red, no hay qué imprimir | [lib/presentation/cashier/services/print_service.dart](lib/presentation/cashier/services/print_service.dart) |
| 37 | Consultar inventario | `SELECT inventory_items, inventory_stock, inventory_movements` | No (para vender) | Falla. Hay vista `v_menu_items_stock` cacheable | [lib/data/repositories/inventory_repository.dart](lib/data/repositories/inventory_repository.dart) |
| 38 | Ver órdenes activas (mesero) | `SELECT orders, table_sessions, order_items` + Realtime channel | Sí | Pantalla muestra última snapshot; sin reconexión automática de Realtime, los cambios nuevos se pierden | [lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart:236-339](lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart) |
| 39 | Devolución (anular item) | UPDATE `order_items.status='void'` + trigger `trg_order_items_reconcile_inventory_*` | Sí | Falla. El trigger reconcilia stock online | [supabase/migrations/20260517_0002_inventory_revert_on_cancel.sql](supabase/migrations/20260517_0002_inventory_revert_on_cancel.sql) |
| 40 | PIN de supervisor (cambio rol, override) | `SELECT employees WHERE pin=...` | Sí | Falla. **No hay PIN local cacheado** | [session_controller.dart:660-712](lib/services/session/session_controller.dart) |

**Conclusión sección 2:** De 40 operaciones críticas o semi-críticas, **24 dependen 100% de red** sin fallback, **8 tienen fallback parcial** (encolado), **6 funcionan plenamente offline** (cálculos locales, impresión ESC/POS, lectura de snapshot, etc.) y **2 dependen de Realtime que no se reconecta solo**.

---

## 3. Autenticación y sesión

### 3.1 Inicialización del cliente Supabase

[lib/main.dart:520-530](lib/main.dart) llama `SupabaseConfig.initialize(url, anonKey)` con timeout de 20s.

[lib/core/network/supabase_config.dart:43-76](lib/core/network/supabase_config.dart) construye el cliente con:

- `authFlowType: AuthFlowType.pkce` (línea 69)
- `autoRefreshToken: true` (línea 70)
- `detectSessionInUri: true` (línea 71)
- **Storage:**
  - Web → `SharedCookieLocalStorage` (cookies wildcard `.mangopos.do`, `Max-Age = 2_592_000` segundos = **30 días**) — [lib/core/network/cookie_local_storage.dart:12,54-56](lib/core/network/cookie_local_storage.dart)
  - Mobile / Desktop → `SharedPreferencesLocalStorage` (clave `supabase.auth.token`) — cookie_local_storage.dart:14
- URL y anon key vienen de [lib/env/env.dart:4-14](lib/env/env.dart). Default URL: `https://supabase.mangopos.do`.

**⚠️ Implementado:** ✅
**⚠️ NO se usa `flutter_secure_storage`** — verificado por búsqueda exhaustiva.

### 3.2 Flujo de login

UI: [lib/presentation/auth/login/login_view.dart](lib/presentation/auth/login/login_view.dart).
Lógica: [lib/presentation/auth/login/login_viewmodel.dart](lib/presentation/auth/login/login_viewmodel.dart).

1. `submit()` (líneas 38-93) — `auth.signInWithPassword(email, password)`.
2. Si `AuthException` con `"email not confirmed"` → muestra campo OTP (líneas 58-66).
3. `verifyOTP()` (líneas 95-120) → `auth.verifyOTP(email, token, OtpType.signup)`.
4. `_handleSuccessfulLogin()` (líneas 122-210):
   - Lee `profiles.full_name`.
   - Lee `user_businesses` filtrado por user_id.
   - Si **0 negocios:** signOut + error.
   - Si **>1 negocio:** redirige a `/select-business` ([lib/presentation/auth/login/select_business_view.dart](lib/presentation/auth/login/select_business_view.dart)).
   - Si **1 negocio:** `sessionProvider.setAuthenticated(...)`.

**Sin login offline.** No hay credenciales cacheadas para entrar sin red la primera vez.

### 3.3 Multi-usuario por terminal — PIN

[lib/services/session/session_controller.dart:660-712](lib/services/session/session_controller.dart) `verifyPin({pin, level})`:

- Hace `SELECT * FROM employees WHERE business_id=? AND status='active' AND pin=?`.
- Si match: valida `level` (any / supervisor / admin) contra `user_businesses.role`.
- **No hay PIN cacheado offline.** Cada verificación pega Supabase.

[lib/presentation/sales/widgets/pin_verification_modal.dart](lib/presentation/sales/widgets/pin_verification_modal.dart) — keypad numérico que llama `verifyPin` asincrónicamente.

**Modo multimesero:** activado por `business_settings.multimesero_enabled` ([lib/core/multimesero/multimesero_repository.dart:20-46](lib/core/multimesero/multimesero_repository.dart)). El mesero ingresa PIN al abrir mesa. Cada item agregado queda atado al `waiter_user_id` del PIN ingresado. **Mismo dependencia online** que arriba.

**Cambio de rol sin re-login (admin↔cajero):** `switchRole()` ([session_controller.dart:601-612](lib/services/session/session_controller.dart)) solo actualiza `state.activeRole` y `state.permissions` en memoria; requiere PIN supervisor por línea 711.

### 3.4 Refresh token y recuperación

[lib/main.dart:773-886](lib/main.dart) `_scheduleExpiredAuthRecovery`:

- Decodifica el JWT (base64) para leer `exp` ([lib/main.dart:888-904](lib/main.dart) `_isJwtExpired`).
- Si está expirado: espera 2s → `auth.refreshSession(refreshToken)`.
- Backoff exponencial (2s, 4s, 8s, ...).
- **Máximo `_maxAuthRecoveryAttempts = 3`** (línea 130).
- Si los 3 reintentos fallan **y todavía hay refreshToken**: preserva sesión local con warning (líneas 835-843).
- Si **no hay refreshToken**: `signOut(SignOutScope.local)` + redirige a login (líneas 846-851).

[lib/main.dart:738-771](lib/main.dart) `_scheduleExpiredAuthReset` (caso schema-mismatch GoTrue↔backend): logout local inmediato + login.

[supabase_config.dart:79-141](lib/core/network/supabase_config.dart):
- `isRecoverableError(error)` — clasifica `SocketException`, `TimeoutException`, códigos PostgreSQL 57014, 08xxx, 40xxx, 53xxx.
- `isAuthRefreshSchemaMismatchError`, `isTransientAuthRefreshError` (502, 500), `isTlsCertificateError`.
- `getFriendlyErrorMessage(error)` — devuelve textos en español.

### 3.5 Cómo se mantiene el state de sesión

[lib/services/session/session_controller.dart](lib/services/session/session_controller.dart) es un **`Notifier<SessionState>` de Riverpod** (línea 247).

- Suscribe a `Supabase.instance.client.auth.onAuthStateChange` (línea 256). Eventos: `signedOut`, `signedIn`, `tokenRefreshed`, `userUpdated`, `initialSession`.
- Cada evento relevante → `restoreFromSupabaseSession(session: session)` (línea 345-477).
- `restoreFromSupabaseSession` (líneas 345-477):
  1. Lee `profiles.full_name`.
  2. Lee `user_businesses` ordenado por `created_at`.
  3. Lee `businesses` filtrados.
  4. Heurística para elegir negocio activo (líneas 421-445): URL query `?business_id=xxx` → cookie domain match (web) → state.activeBusinessId previo → primero de la lista.
  5. `_activateBusiness(businessId)` (línea 494+).
  6. `_loadEffectivePermissions()` (líneas 770-832): RPC `fn_user_effective_permissions(user_id, business_id)`. Owner/admin reciben wildcard `*`. Fallback en falla: preset de rol en [lib/core/security/access_control_catalog.dart](lib/core/security/access_control_catalog.dart).

`SessionState` (líneas 185-208) **vive solo en memoria de Riverpod**. No se persiste explícitamente — depende del JWT en storage.

### 3.6 Claims y RLS

**No se cachean claims del JWT en cliente.** El cliente:
1. Recibe JWT firmado de GoTrue.
2. Lo manda en headers en cada request.
3. RLS extrae `auth.uid()` y compara contra tablas de membresía (`user_businesses`, `businesses.owner_id`).

**Políticas RLS críticas** (extracto de [supabase/schema.sql](supabase/schema.sql)):

| Tabla | Política | Línea | Lógica |
|---|---|---|---|
| `orders` | Staff can manage orders | 4797 | `has_business_role(auth.uid(), business_id, ['owner','admin','cashier','waiter'])` |
| `orders` | Users can view business orders | 4803 | `user_has_business_access(auth.uid(), business_id)` SELECT only |
| `order_items` | Users can view order items | 4809 | `user_has_business_access(...)` |
| `cash_registers` | Access by business | 4763 | `auth.uid() IN (SELECT user_id FROM user_businesses WHERE business_id=...)` |
| `cash_register_sessions` | Access via cash_registers | 4769 | indirecto |
| `cash_count_blind` | cashier_rw | mig 20260510_0002:121-132 | `user_has_business_access(...) AND signed_by_user_id = auth.uid()` |
| `menu_items`, `categories`, `dining_tables`, `zones` | view own business data | 4816-4828 | `user_has_business_access(...)` SELECT, `has_business_role([owner,admin])` WRITE |
| `business_settings` | bs_admin / bs_select | 4847-4851 | admin/owner WRITE; cualquier miembro SELECT |
| `printers` | is_admin_of_business | 4957-4961 | INSERT/UPDATE/DELETE solo admin/owner |

**Funciones RLS clave:**

- `user_has_business_access(_user_id, _business_id)` ([schema.sql:2170-2185](supabase/schema.sql)) — EXISTS en `user_businesses` OR `businesses.owner_id`.
- `user_business_role(_user_id, _business_id)` ([schema.sql:2154-2166](supabase/schema.sql)) — coalesce de `user_businesses.role` y `'owner'` si es dueño.
- `has_business_role(_user_id, _business_id, _roles[])` ([schema.sql:1881-1888](supabase/schema.sql)) — wrapper.
- `fn_user_in_business(p_business_id)` ([schema.sql:1831-1839](supabase/schema.sql)) — EXISTS con `auth.uid()` implícito.

**Implicación offline:** **toda lectura/escritura requiere JWT válido**. Si Supabase está caído pero el cliente cree que tiene JWT válido, la query lanza PostgrestException; si el JWT expiró sin red para refrescar, todo falla con 401.

### 3.7 JWT TTL

⚠️ **PENDIENTE DE VERIFICAR** — vive en variables de entorno de GoTrue en Coolify (`GOTRUE_JWT_EXP`, `GOTRUE_REFRESH_TOKEN_ROTATION_*`). El cliente no lo configura. Hasta confirmación, asumimos **7 días** (mencionado por el solicitante del PRD).

Implicación: si un terminal pierde internet por más de `JWT_EXP` segundos y el refresh falla, queda fuera. Con 7 días de TTL, un POS de restaurante que cierra la noche y abre al día siguiente sobrevive sin problema; pero un terminal apagado por una semana entera entra con la sesión muerta.

### 3.8 Brechas para offline (sin proponer solución)

- **Sin login offline:** la primera vez en un dispositivo nuevo, ningún flujo funciona sin red.
- **Refresh requiere red:** si expira el access token y no hay internet, los 3 reintentos fallan y el comportamiento depende de si el refreshToken existe en storage.
- **PIN verification 100% online:** cada uso del PIN va a Supabase.
- **RLS bloquea todo si el JWT está caducado/inválido:** no hay modo "trust local" — cualquier query falla.
- **Permisos cached en memoria, no en disco:** un kill de la app pierde los permisos hasta el siguiente `restoreFromSupabaseSession()` (que requiere red).

---

## 4. Capa de datos

### 4.1 Cliente Supabase

- **`supabase_flutter: ^2.10.0`** ([pubspec.yaml:40](pubspec.yaml))
- **`flutter_riverpod: ^2.6.1`** ([pubspec.yaml:37](pubspec.yaml))
- **Configuración:** ver §3.1.

### 4.2 ¿Existe BD local?

**No hay BD relacional local.** Búsqueda exhaustiva:

```
grep -rn "openDatabase\|Database.open\|drift\|Isar\|Sembast" lib/
# → 0 coincidencias
```

Dependencias de SQL/NoSQL en pubspec.yaml: ❌ no aparecen `sqflite`, `drift`, `isar`, `hive`, `sembast`.

**Lo que sí existe:**

| Servicio | Ubicación | Qué guarda | Persistencia |
|---|---|---|---|
| `StorageService` (Singleton) | [lib/core/storage/storage_service.dart:34-217](lib/core/storage/storage_service.dart) | Wrapper sobre `SharedPreferences`. Métodos `read`, `write`, `readJson`, `writeJson`, `readList`, `deleteByPrefix` | SharedPreferences (clave-valor) |
| `CacheManager` | [lib/core/cache/cache_manager.dart:25-567](lib/core/cache/cache_manager.dart) | Caché con estrategias `cacheFirst`, `networkFirst`, `cacheOnly`, `networkOnly`. TTL por módulo. Hash MD5 de datos. Metadata (`cachedAt`, `expiresAt`, `lastSyncedAt`, `sizeInBytes`) | SharedPreferences |
| `OfflineCatalogService` | [lib/core/offline/offline_catalog_service.dart:152-226](lib/core/offline/offline_catalog_service.dart) | Snapshot de categorías, menús, productos, impuestos. Tracking de `max(updated_at)` para delta-detection (líneas 27-28) | SharedPreferences, clave `offline_catalog_{businessId}` |
| `OfflinePosService` | [lib/core/offline/offline_pos_service.dart:35-56](lib/core/offline/offline_pos_service.dart) | Cola de acciones pendientes (`offline_queue_{businessId}`), snapshots de órdenes locales (`offline_snapshot_{businessId}_{slotId}`), mapeo de IDs locales → remotos, fingerprints para deduplicación | SharedPreferences |
| `cached_network_image` (^3.4.1) | [pubspec.yaml:89](pubspec.yaml) | Caché de imágenes de productos | Disco (gestionado por el package) |

**Invalidación de caché:**

- [cache_manager.dart:185-224](lib/core/cache/cache_manager.dart) — al detectar version mismatch app/cache, limpia todos los `cache_*`, `metadata_*`, `queue_*`.
- Manual: `CacheManager.clearSystemCache()` ([cache_manager.dart:50-106](lib/core/cache/cache_manager.dart)).

### 4.3 Patrón de fetch

**PostgREST directo** desde repositorios en [lib/data/repositories/](lib/data/repositories/) (31 archivos, uno por dominio).

Ejemplo típico — [lib/data/repositories/menu_repository.dart:6-77](lib/data/repositories/menu_repository.dart):

```dart
final res = await q.order('created_at', ascending: true);
return (res as List).map((e) => Menu.fromMap(e)).toList();
```

**Sin timeout explícito y sin retries en este nivel.** Los timeouts/reintentos están centralizados en `DatabaseOperationWrapper` (ver §4.5) pero **no se invocan desde los repos existentes**.

Queries SQL constantes en [lib/data/datasources/queries/](lib/data/datasources/queries/) (12 archivos), ej. [sales_queries.dart](lib/data/datasources/queries/sales_queries.dart).

### 4.4 State management

**Riverpod 2.6.1** ([pubspec.yaml:37](pubspec.yaml)).

Patrones detectados:

- `Notifier<T>` y `StateNotifier<T>` — ej. [session_controller.dart:247](lib/services/session/session_controller.dart), [sales_viewmodel.dart:31](lib/presentation/sales/viewmodel/sales_viewmodel.dart).
- `family` — ej. [payment_split_viewmodel.dart:154](lib/presentation/sales/viewmodel/payment_split_viewmodel.dart), `menuBrowserVmProvider`.
- `autoDispose` — uso parcial. Mencionado en `paymentSplitProvider`, `detailedWizardProvider`.

State sobrevive a logout solo si el provider no es autoDispose y el árbol Riverpod no se reconstruye.

### 4.5 Manejo de errores de red

[lib/core/network/supabase_config.dart:7-208](lib/core/network/supabase_config.dart) define **timeouts y retries genéricos**, pero **no están enchufados a los repos**:

- Read timeout: 15s (línea 22).
- Write timeout: 20s (línea 25).
- RPC timeout: 25s (línea 28).
- Startup `Supabase.initialize` timeout: 20s ([main.dart:523-527](lib/main.dart)).
- Max retries: 3 (línea 31).
- Initial delay: 500ms (línea 34).
- Backoff: exponencial x2 + jitter aleatorio (líneas 84-88).

[lib/core/network/database_operation_wrapper.dart:8-187](lib/core/network/database_operation_wrapper.dart) — **wrapper implementado pero NO USADO**:

```
grep -rn "DatabaseOperationWrapper.execute\|.read\|.write" lib/data/repositories/
# → 0 coincidencias
```

Cada repo hace queries directas sin wrapper. ⚠️ **Implementado pero huérfano.**

**Mensajes amigables de error:** `SupabaseConfig.getFriendlyErrorMessage(error)` (líneas 144-190) cubre auth mismatch, TLS cert, códigos PostgreSQL, `SocketException`, `TimeoutException`, `FormatException`. Se usa en la mayoría de los catch de UI.

**Banner global "Sin conexión":** ⚠️ **NO existe**. La detección de conectividad sí existe (ver siguiente sección) pero no hay banner visible global.

### 4.6 Connectivity awareness

[lib/core/network/connectivity_service.dart:6-103](lib/core/network/connectivity_service.dart):

- Singleton. Stream de cambios. `isConnected` boolean.
- `initialize()` debe llamarse antes.
- Considera WiFi, mobile, ethernet como conectados (excluye Bluetooth, líneas 71-74).
- `simulateDisconnect()`, `simulateReconnect()` para testing (líneas 85-92).

**Usos confirmados:**

- [menu_browser_viewmodel.dart:340-360](lib/presentation/sales/viewmodel/menu_browser_viewmodel.dart) — si offline, `_ensureCatalogSnapshot` devuelve snapshot local.
- [sales_viewmodel.dart:124-137](lib/presentation/sales/viewmodel/sales_viewmodel.dart) — escucha reconexión para drenar cola offline (`syncPendingOfflineActions`).
- [cache_manager.dart:372,474](lib/core/cache/cache_manager.dart) — si offline, devuelve datos stale; si online, sincroniza.

### 4.7 Pantalla → query inicial → comportamiento sin red

| Pantalla | Query / RPC inicial | Timeout | Reintentos | Comportamiento offline |
|---|---|---|---|---|
| Login | `auth.signInWithPassword` + `SELECT profiles, user_businesses, businesses` | 20s startup; sin timeout explícito en signIn | 3 (SupabaseConfig pero solo en path de refresh, no en signIn) | TimeoutException → mensaje "Tiempo de espera agotado" |
| Restore session (post-login) | `SELECT profiles; SELECT user_businesses; SELECT businesses` + RPC `fn_user_effective_permissions` | 15s | 3 (solo refresh) | Si falla: preserva estado anterior si JWT en storage sigue válido |
| Sales / Cashier home | `menuBrowserVmProvider.loadAll()` → `SELECT v_menu_items_for_business, categories, menus` | 15s | 0 | Carga snapshot local de OfflineCatalogService |
| Open table (mesa) | RPC `fn_open_table` | 25s | 0 | Falla. **Sin fallback ni encolado** |
| Add item to order | RPC `fn_add_item_from_menu` | 25s | 0 | Encolado en `OfflinePosService` (acción `add_item`) |
| Confirm to kitchen | RPC `fn_confirm_order_to_kitchen` | 25s | 0 | Acción `send_to_kitchen` encolada; descuento de inventario diferido |
| Payment / cobro | RPC `fn_process_payment_v3` | 25s | 0 (excepto recovery por unique violation) | **CRÍTICO: sin red falla. No hay queue de pagos** |
| Imprimir | TCP/USB/BT local | TCP timeout 5s (USB 30s + 3 reintentos 0/2/5s) | 3 USB; 0 BT/TCP | Funciona si la impresora está en LAN/USB local |
| Inventory hub | `SELECT inventory_items, inventory_stock, inventory_movements` | 15s | 0 | Falla; no hay caché de inventario completo |
| Sales by zone | `SELECT zones, tables, table_sessions, orders, payments` + Realtime | 15s | 0 | Carga última snapshot del fetch; Realtime sin reconnect automático |

---

## 5. Escrituras y consistencia

### 5.1 Inventario de RPCs llamados desde Dart

Definidos como constantes en [lib/data/datasources/queries/sales_queries.dart:1-197](lib/data/datasources/queries/sales_queries.dart) e invocados desde repos. Lista completa:

| RPC | Llamada Dart | Definición SQL | Propósito |
|---|---|---|---|
| `fn_open_table` | sales_repository.dart:286 | mig 20260303_0008:86 | Abre mesa + sesión + orden + check inicial |
| `fn_open_manual_or_quick` | sales_repository.dart:318 | ⚠️ pendiente | Abre venta manual o quick sale |
| `fn_add_item_from_menu` | sales_repository.dart:555 | mig 20260508_0002:18 | Agrega item con cálculo de tax_profile y triggers de tax_lines |
| `fn_update_item_qty` | sales_queries.dart:136 | ⚠️ pendiente | Actualiza qty (sin uso confirmado) |
| `fn_update_item_notes` | sales_queries.dart:139 | ⚠️ pendiente | Actualiza notas |
| `fn_update_item_details` | sales_queries.dart:140 | ⚠️ pendiente | Actualiza detalles |
| `fn_update_item_discount` | sales_queries.dart:141 | mig 20260305_0011:1 | Actualiza descuento |
| `fn_update_item_discount_and_notes` | sales_queries.dart:142 | ⚠️ pendiente | Descuento + notas (cortesía) |
| `fn_delete_item` | sales_queries.dart:146 | ⚠️ pendiente | Borra item |
| `fn_move_item_to_check`, `fn_move_items_to_check_batch` | sales_queries.dart:149-150 | ⚠️ pendiente | Mueve items a otro check |
| `fn_toggle_item_takeout` | sales_queries.dart:153 | mig 20260502_0002:1 | Toggle takeout |
| `fn_confirm_order_to_kitchen` | sales_repository.dart:1279 | mig 20260308_0017:89 | Envía a cocina + dispara `consume_inventory_from_order` vía trigger |
| `fn_close_order_and_table` | sales_queries.dart:159 | mig 20260516_0017:34 | Cierra orden + libera mesa |
| `fn_create_split_bill` | sales_queries.dart:162 | mig 20260303_0008:167 | Crea sub-checks |
| `fn_split_items_equally`, `fn_explode_items_to_units` | sales_queries.dart:163-168 | mig 20260327_0009, 20260513_0011 | Operaciones de split |
| `fn_consolidate_order_to_integer` | sales_queries.dart:172 | ⚠️ pendiente | Consolida fracciones |
| `fn_set_check_customer_and_ncf` | sales_repository.dart:1170 | mig 20260323_0004:1 | Asigna cliente + tipo NCF al check |
| `fn_get_order_bundle` | sales_queries.dart:182 | mig 20260309_0009:1 | Bundle de orden + items + checks + customer |
| **`fn_process_payment_v3`** | sales_repository_improved.dart:322 | mig 20260513_0007:41 | **Pago atómico idempotente con SELECT FOR UPDATE** |
| `generate_ncf` | (indirecto, trigger) | mig 20260426_0001:211 | Genera NCF tomando `FOR UPDATE` la secuencia |
| `create_fiscal_document` | sales_repository.dart:1793 | mig 20260513_0002:84 | Crea fiscal_document |
| `fn_open_delivery_order`, `fn_list_delivery_orders`, `fn_close_delivery_order` | sales_queries.dart:194-196 | ⚠️ pendiente | Delivery |
| `fn_assign_customer_to_session` | sales_repository.dart:488 | ⚠️ pendiente | Cliente → sesión |
| `fn_assign_manual_order_to_table` | sales_repository.dart:286 | ⚠️ pendiente | Manual order → mesa |
| `fn_mark_order_takeout` | sales_repository.dart:1859 | ⚠️ pendiente | Marca takeout |
| `fn_open_cash_session` | cashier_repository.dart (varios) | mig ⚠️ pendiente | Abre caja |
| `fn_close_cash_session` | cashier_repository.dart:96-150 | mig ⚠️ pendiente | Cierra caja con validación OPEN_TABLES_EXIST |
| `fn_get_cash_session_summary` | cashier_repository.dart:215-232 | ⚠️ pendiente | Reporte Z |
| `fn_user_effective_permissions` | session_controller.dart:781-784 | ⚠️ pendiente | Permisos efectivos por user/business |
| `consume_inventory_from_order` | trigger | mig 20260516_0013:32 + 20260517_0002 | Descuenta/devuelve stock |
| `fn_recompute_menu_items_availability` | trigger | mig 20260516_0015 + 20260517_0001 | Auto-86 + flag `allow_negative_sale` |
| `fn_menu_item_set_inventory_tracked` | products_repository.dart:158-168 | ⚠️ pendiente | Toggle tracking de inventario por producto |

### 5.2 Transaccionalidad

**Todas las RPCs son transaccionales (PL/pgSQL = 1 RPC = 1 transacción).** No hay BEGIN/COMMIT explícitos en el código Dart porque PostgREST los envuelve.

Operaciones críticas con garantías reforzadas:

- **`fn_open_table`** ([mig 20260303_0008:86-159](supabase/migrations/20260303_0008_sales_split_open_table_full_fix.sql)) — usa `pg_advisory_xact_lock` (serializa concurrentes sobre la misma mesa).
- **`fn_process_payment_v3`** ([mig 20260513_0007:41-282](supabase/migrations/20260513_0007_rpc_refresh_payment_before_return.sql)) — `SELECT ... FOR UPDATE` sobre `orders` y `order_checks`. Guard de idempotencia que retorna el payment ya completado si existe.
- **`fn_confirm_order_to_kitchen`** ([mig 20260308_0017:89-108](supabase/migrations/20260308_0017_sales_inventory_autoconsume.sql)) — UPDATE + `PERFORM consume_inventory_from_order(p_order_id)`. El trigger `consume_inventory_from_order` (reescrito en mig 20260517_0002) es **idempotente reconciliadora**: calcula `expected_qty − net_consumed = delta` y emite movement con signo apropiado.

### 5.3 Idempotencia

#### IDs

- **Servidor:** `gen_random_uuid()` en INSERTs de `orders`, `order_items`, `payments`, `order_checks`, `cash_register_sessions`, `cash_count_blind`, `fiscal_documents`.
- **Cliente (solo offline):** `'local-order-${_uuid.v4()}'`, `'local-session-${_uuid.v4()}'`, `'tmp_<uuid>'` para items en cola — [lib/core/offline/offline_pos_service.dart:39,139](lib/core/offline/offline_pos_service.dart). Se mapean post-sincronización en `remapSnapshotOrderId()` (línea 105).

#### Pagos — triple defensa

1. **Guard en RPC** ([mig 20260513_0007:81-131](supabase/migrations/20260513_0007_rpc_refresh_payment_before_return.sql)) — al inicio del RPC, busca si ya existe un payment `completed` para `(order, check)` actual. Si existe, lo devuelve (idempotencia).
2. **Unique partial index** ([mig 20260510_0004:63-70](supabase/migrations/20260510_0004_payment_split_sequence.sql)):
   ```sql
   CREATE UNIQUE INDEX payments_unique_completed_per_check_method_seq
   ON payments (order_id, COALESCE(check_id, '00..0'::uuid), payment_method_id, split_sequence)
   WHERE status = 'completed';
   ```
3. **Recovery en cliente** ([sales_repository_improved.dart:373-383](lib/data/repositories/sales_repository_improved.dart)) — al recibir 23505 PostgrestException, busca el payment existente y lo retorna.

#### NCF — protección contra colisiones

`generate_ncf` ([mig 20260426_0001:211-272](supabase/migrations/20260426_0001_fix_ncf_collisions_and_trigger_idempotency.sql)):

- `SELECT * FROM ncf_sequences ... FOR UPDATE LIMIT 1`.
- Detecta `MAX(ncf_number)` ya usado en `fiscal_documents` (línea 230). Salta al máximo si excede `current_number + 1`.
- Si colisiona 200+ veces: el cliente intenta recuperar payment vía `_recoverCompletedPaymentAfterNcfCollision` ([sales_repository_improved.dart:354+](lib/data/repositories/sales_repository_improved.dart)).

### 5.4 Cola de escrituras pendientes (offline)

[lib/core/offline/offline_pos_service.dart](lib/core/offline/offline_pos_service.dart) — cola persistente en SharedPreferences.

**Storage keys:**
- `offline_queue_{businessId}` — lista de acciones.
- `offline_snapshot_{businessId}_{slotId}` — estado de orden actual (líneas 50).
- `offline_print_queue_{businessId}` — cola de impresión (línea 51).
- `offline_order_map_{businessId}`, `offline_item_map_{businessId}` — mapeo IDs locales → remotos.
- `offline_completed_ops_{businessId}`, `offline_completed_fingerprints_{businessId}` — set de fingerprints completados (deduplicación).

**Estructura de una acción** ([líneas 314-351](lib/core/offline/offline_pos_service.dart)):

```dart
{
  'id': 'offline-op-${uuid}',
  'type': 'add_item' | 'delete_item' | 'update_item_quantity' | ...,
  'status': 'pending' | 'processing' | 'completed' | 'failed',
  'attempts': 0,
  'queued_at': ISO_8601,
  'fingerprint': hash(type|orderId|itemId|menuItemId|productId|checkPos|qty|takeout|notes),
  ... payload
}
```

**Tipos de acciones soportadas** (detectados en `_compactQueue` [líneas 363-431](lib/core/offline/offline_pos_service.dart)):
- `add_item`, `delete_item`, `update_item_quantity`, `update_item_notes`, `toggle_item_takeout`, `move_item_to_check`, `mark_order_takeout`, `send_to_kitchen`, `confirm_local_order`.

**⚠️ NO encolados:**
- `fn_open_table`, `fn_open_manual_or_quick` — abrir orden requiere red.
- `fn_process_payment_v3` — **cobrar requiere red**.
- `fn_close_cash_session`, `fn_open_cash_session` — caja requiere red.
- `generate_ncf`, `create_fiscal_document` — fiscal requiere red.
- `fn_update_item_discount*` — descuentos/cortesías no se encolan.

**Compactación** ([líneas 353-438](lib/core/offline/offline_pos_service.dart)):

Si una secuencia local genera un item con `tmp_id` y luego se borra, se compactan: el `add_item` se elimina cuando aparece el `delete_item`. Mismo patrón para merge de qty/notes/takeout sobre items aún no sincronizados.

**Sincronización** ([líneas 202-303](lib/core/offline/offline_pos_service.dart)):

`syncPendingActions({businessId, salesRepository, printingService, force})`:

1. Skip si ya `completed` o fingerprint en set.
2. Backoff exponencial entre intentos (2^attempts segundos, con cap).
3. **Para en el primer fallo** — no continúa la cola si una acción falla.

Se dispara desde [sales_viewmodel.dart:124-137](lib/presentation/sales/viewmodel/sales_viewmodel.dart) cuando se detecta reconexión.

### 5.5 NCF y emisión fiscal

#### Asignación

- Tabla `ncf_sequences` con rangos pre-cargados por negocio + tipo (`ncf_type` enum: FCF/NCF/RCD/...).
- Generación server-side, `FOR UPDATE` de la secuencia, salto al `MAX` ya usado para evitar duplicados.

#### Cuándo se asigna

1. **Pre-pago (opcional):** `fn_set_check_customer_and_ncf(check_id, customer_id, ncf_type)` ([sales_repository.dart:1170](lib/data/repositories/sales_repository.dart)) cuando el cajero asigna RNC/cédula al cliente antes de cobrar.
2. **En el pago:** se pasa `p_requested_ncf_type` a `fn_process_payment_v3`.
3. **Post-pago:** trigger genera NCF + crea `fiscal_documents` row + `UPDATE payments SET fiscal_document_id = fd.id`.
4. **Refresh:** mig 20260513_0007 hace `SELECT * FROM payments WHERE id=v_payment_id` antes del `RETURN` para que el cliente reciba el `fiscal_document_id` ya seteado.

#### e-CF (electrónico) síncrono

Tras el pago exitoso del modal compacto/wizard, [table_order_screen.dart:1760-1780](lib/presentation/sales/view/table_order_screen.dart) invoca **edge function `emit-document`** vía `Supabase.instance.client.functions.invoke('emit-document', ...)`:

```dart
// si fiscal_document.is_electronic = true:
final res = await Supabase.instance.client.functions
    .invoke('emit-document', body: {...});
```

Si falla: el ticket sale con leyenda "Pendiente de emisión a DGII" y queda un job para el cron de respaldo (~60s).

#### Comportamiento sin red

❌ **NO funciona offline:**
- No hay reserva client-side de rangos NCF.
- `generate_ncf` solo corre con DB online.
- La cola offline `OfflinePosService` **no encola pagos** ni `create_fiscal_document`.
- Implicación: sin internet, no se puede facturar — el cajero queda bloqueado.

### 5.6 Generación de números visibles

- **Order ID:** UUID server-side. No hay número correlativo visible al cliente.
- **Ticket number:** ⚠️ no se encontró columna `ticket_number`. El ticket se identifica con `order.id.substring(0,8).toUpperCase()` (ej. `8DDDA88C`) en la UI ([table_order_screen.dart:1455](lib/presentation/sales/view/table_order_screen.dart) y reportes).
- **NCF:** `prefix || LPAD(number, 8, '0')` — ej. `B0200002389`.

### 5.7 Tabla resumen

| Operación de escritura | Crítica venta | Atómica server | Idempotente | Funciona offline |
|---|---|---|---|---|
| `fn_open_table` | Sí | Sí (advisory lock) | Sí (reusa sesión/orden) | No |
| `fn_add_item_from_menu` | Sí | Sí | No (cada llamada = item nuevo) | Sí (encolado en `OfflinePosService`) |
| `fn_confirm_order_to_kitchen` | Sí | Sí | Sí (trigger gate por `status_ext`) | Parcial (acción encolada; descuento de stock solo online) |
| `fn_process_payment_v3` | **Sí (crítica)** | Sí (FOR UPDATE) | Sí (guard + UNIQUE + recovery cliente) | **No** |
| `create_fiscal_document` (trigger) | Sí | Sí | Sí (busca existing por order/payment) | No |
| `fn_close_cash_session` | Sí | Sí | Sí (idempotente; UPDATE) | No |
| `fn_open_cash_session` | Sí | Sí | ⚠️ verificar | No |
| `fn_update_item_discount` | Sí | Sí | No | No (no encolado) |
| `fn_delete_item` / `fn_update_item_qty` | Medio | Sí | No | Sí (encolado) |

---

## 6. Impresión

### 6.1 Estado de PRD 5 (Unified Printing Module)

**Implementación: ~95% completa.**

| Entregable | Estado | Notas |
|---|---|---|
| ESC/POS generator | ✅ | [lib/services/printing/esc_pos_generator.dart](lib/services/printing/esc_pos_generator.dart) — genera bytes raw, alineación, QR, banners inversos |
| Templates de ticket | ✅ | [lib/services/printing/print_ticket_service.dart](lib/services/printing/print_ticket_service.dart) (~1700 líneas) — `generateKitchenTicket`, `generatePrecheck`, `generateInvoice`, `generateFiscalInvoice`, `generateCashCloseTicket`, `generateCashMovementReceipt` |
| QR ESC/POS | ✅ | [qr_esc_pos_builder.dart](lib/services/printing/qr_esc_pos_builder.dart) — para e-CF |
| TCP directo (`:9100`) | ✅ | [printing_repository.dart:1235-1469](lib/data/repositories/printing_repository.dart) |
| USB (con 3 reintentos) | ✅ | printing_repository.dart, retry 0s/2s/5s |
| Bluetooth | ✅ | [bluetooth_print_service.dart](lib/core/printing/bluetooth_print_service.dart) vía `flutter_blue_plus_windows` |
| Multi-device routing (mismo business, otro dispositivo en LAN) | ✅ | `_printViaRemoteHost` |
| Cloud queue fallback | ✅ | INSERT a `print_jobs` (mig 20260... pendiente identificar). Procesado por agent Node.js |
| Health dashboard | ✅ | Settings → Print Health con Realtime sobre `print_jobs` |
| Local agent móvil | ✅ | [lib/core/agent/mobile_print_agent.dart](lib/core/agent/mobile_print_agent.dart) — agent HTTP embebido en `localhost:4000` en Android/iOS |
| Agent LAN Node.js (Windows) | ⚠️ Parcial | `agent/` existe con `job_processor.js`, `escpos_helpers.js`. Templates específicos hardcoded |
| mDNS discovery | ✅ | [main.dart:159-188](lib/main.dart) `_discoverHubsViaMdns` |

### 6.2 Tipos de impresora soportados

| Tipo | Archivo responsable | Depende de Supabase | Imprime offline |
|---|---|---|---|
| Network (TCP `:9100`) | printing_repository.dart `_printEscPosLocal` | Solo cloud queue fallback | ✅ Sí (si printer en LAN local) |
| USB nativo | `flutter_usb_printer` (mobile/desktop) | Solo cloud queue fallback | ✅ Sí |
| USB en web | Agente local HTTP requerido | Agente, no Supabase | ✅ Sí si agent activo |
| Bluetooth | `flutter_blue_plus_windows` | No | ✅ Sí |
| Multi-device (host_device_id) | `_printViaRemoteHost` (HTTP LAN) | LAN | ⚠️ Solo si el otro device es alcanzable |
| Cloud queue | INSERT a `print_jobs` (Supabase) | **Sí (crítico)** | ❌ No |

### 6.3 Flujo de impresión (escalada)

[printing_repository.dart:1235-1469](lib/data/repositories/printing_repository.dart) — secuencia de intentos:

```
printEscPos(printer, data, idempotencyKey)
├─ Si printer.hostDeviceId != thisDevice → _printViaRemoteHost (LAN HTTP)
├─ Si tipo network → TCP directo (timeout 5s)
├─ Si TCP falló → agente local HTTP (`localhost:4000` o LAN agent)
├─ Si tipo USB → 3 reintentos (0s, 2s, 5s backoff)
├─ Si tipo BT → BluetoothPrintService.printRaw
└─ Si todos fallan + idempotencyKey presente → _escalateToCloudQueue (INSERT a print_jobs)
```

### 6.4 Plantillas y configuración

- **Templates embebidos en código.** No se descargan de Supabase.
- **Configuración por negocio** (logo, footer, fiscal NCF) viene de `business_settings` y `fiscal_settings` (tablas Supabase). Requiere red para cargar inicialmente; luego se cachea en memoria.

### 6.5 Brechas para offline

- **Headers/footers/logo del business:** cargados de Supabase. Si el primer print del día es offline y el cliente no tiene cache, el ticket sale sin logo.
- **Cloud queue:** sin internet, los jobs no se persisten al backend. La cola local sí persiste (`offline_print_queue_{businessId}` en `OfflinePosService`), pero se drena solo cuando vuelve la red.
- **Multi-device routing:** requiere LAN. Si dos terminales están en redes distintas (improbable), falla.

---

## 7. Sesión de caja y multi-business

### 7.1 Tabla `cash_register_sessions`

[supabase/schema.sql](supabase/schema.sql) (líneas no extraídas exhaustivamente):

```sql
cash_register_sessions (
  id uuid PK,
  cash_register_id uuid FK → cash_registers,
  user_id uuid FK → auth.users,
  device_id text,
  device_name text,
  status enum ('open', 'closed'),
  opened_at timestamptz,
  closed_at timestamptz NULL,
  start_amount numeric,
  end_amount numeric NULL,
  notes text NULL,
  close_mode_used enum ('blind', 'detailed') NULL,
  created_at timestamptz
)
```

**RLS:** `cash_register_id IN (SELECT id FROM cash_registers WHERE business_id IN (SELECT business_id FROM user_businesses WHERE user_id = auth.uid()))`.

### 7.2 Apertura

[cashier_repository.dart:65-94](lib/data/repositories/cashier_repository.dart) → RPC `fn_open_cash_session(register_id, user_id, start_amount, device_id)`.

Validaciones server-side:
- Mismo user no tiene otra sesión abierta en el mismo register (Rule B post-fix).
- Cash register pertenece al business del user.

[lib/presentation/cashier/viewmodel/cashier_viewmodel.dart](lib/presentation/cashier/viewmodel/cashier_viewmodel.dart) tiene `ensureCashOpenFast()` que llama al método anterior. Si falla, muestra modal.

### 7.3 Cierre

- **Modo compacto:** [lib/presentation/cashier/widgets/blind_cash_close_dialog.dart](lib/presentation/cashier/widgets/blind_cash_close_dialog.dart). Un modal único — efectivo + tarjeta + transferencia. Al confirmar, llama `closeSessionWithVarianceCheck` ([variance_confirm_dialog.dart:169-214](lib/presentation/cashier/widgets/variance_confirm_dialog.dart)) que: ① si la varianza supera el umbral, pide nota obligatoria al admin/manager; ② llama RPC `fn_close_cash_session(session_id, end_amount, notes, force_with_open_tables)`.
- **Modo detallado:** [lib/presentation/cashier/detailed_wizard/cash_close_detailed_wizard.dart](lib/presentation/cashier/detailed_wizard/cash_close_detailed_wizard.dart). Wizard de 3 pasos. Tras firmar, hace INSERT directo a `cash_count_blind` (vía `recordDetailedCashClose`, [cashier_repository.dart:159-183](lib/data/repositories/cashier_repository.dart)) **además** del `fn_close_cash_session`.

`fn_close_cash_session` valida: si `forceWithOpenTables=false`, lanza `OPEN_TABLES_EXIST` si hay órdenes con `session_id` de esa caja y status no pagado/void.

**Inmutabilidad de cash_count_blind** ([mig 20260510_0002:94-113](supabase/migrations/20260510_0002_cash_count_blind.sql)): trigger `reject_cash_count_blind_modifications` impide UPDATE/DELETE post-firma. Hasta 2 filas por sesión (`attempt_number` 1 = original, 2 = reconteo — mig 20260519_0001).

### 7.4 Reconteo (feature reciente)

Implementado en [docs/ — sesión 2026-05-19](docs/) (sin doc dedicado, conversación trabajada en sesión actual):
- Toggle `business_settings.allow_recount` (mig 20260518_0004).
- Si activo: en el step de resultado (post-firma + impresión), aparece botón "Volver a contar".
- Confirma → audit log + reset state + nuevo conteo con `attempt_number=2`.
- Solo aplica al modo detallado.

### 7.5 Multi-business

[lib/core/business/business_resolver.dart:16-94](lib/core/business/business_resolver.dart) `BusinessResolver.ensure('auto')` — orden de resolución:

1. Cache estático en memoria (`_activeBusinessId`).
2. Storage local (`StorageService`) en mobile/desktop.
3. `user.userMetadata['business_id']`.
4. `user_businesses` (most recent).
5. `memberships` legacy.
6. `businesses.owner_id = user.id`.

[lib/services/session/session_controller.dart:479-492](lib/services/session/session_controller.dart) `switchBusiness(businessId)` — re-ejecuta `_activateBusiness()` y limpia state de pantallas.

### 7.6 Aislamiento por negocio

- **Cliente:** casi todos los repos hacen `.eq('business_id', businessId)` explícito antes de la query.
  - `grep -rn "eq('business_id'" lib/data/repositories/` → 20+ matches.
- **Server:** RLS via `user_has_business_access(auth.uid(), business_id)` o via FK indirectos.
- **Defensa en profundidad:** ambos filtros aplicados simultáneamente.

### 7.7 Bug histórico de cash session multi-business

Documentado en [docs/PRD_CAJA_PROFESIONAL.md:30+](docs/PRD_CAJA_PROFESIONAL.md):

- **Problema previo:** la búsqueda de "caja activa" filtraba por `user_id` global, no por `register_id`. Cuando un cajero abría caja, otros empleados del local (mesero/admin) veían "Caja cerrada" y no podían vender.
- **Fix aplicado** (commits 2026-05-04):
  - `cashier_repository.getActiveSessionForRegister(registerId)` ([cashier_repository.dart:334-349](lib/data/repositories/cashier_repository.dart)) — busca sesión abierta de un register **sin filtrar por user**.
  - `cashier_viewmodel.init()` y `ensureCashOpenFast()` usan el método nuevo.
- **Pendiente:** autorización de cierre por gerencia (admin/manager puede cerrar caja ajena) — documentado en PRD_CAJA_PROFESIONAL.md como Mejora #1, no implementado aún.

### 7.8 Sesiones largas

No hay constraint de `closed_at < opened_at + N hours`. El cliente confirma que en RD las cuentas pueden pagarse al día siguiente — las sesiones >24h son comportamiento esperado.

### 7.9 Brechas offline

- **Apertura/cierre 100% online** (RPCs).
- **Conteo ciego: INSERT directo** — sin red falla.
- **Reporte Z: RPC** — sin red falla.
- **Variance threshold y notas obligatorias** requieren queries adicionales que dependen de red.

---

## 8. Sincronización en tiempo real

### 8.1 Canales activos

Búsqueda exhaustiva: `grep -rn ".channel(" lib/`.

| Canal | Tablas suscritas | Pantalla | Filtro | Eventos |
|---|---|---|---|---|
| `zones:status` | table_sessions, orders, order_items, order_checks, payments, dining_tables | Sales por zona | Sin filtro (all) | INSERT, UPDATE, DELETE | 
| `order_view_$orderId` | order_items, order_checks, orders, payments | Detalle de mesa | `order_id = $orderId` | INSERT, UPDATE, DELETE |
| `sales_by_zone_$businessId` | table_sessions, orders, order_items, payments, order_checks | Sales by zone dashboard | Sin filtro (logical filter por sessionId/zoneId) | ALL |
| `rt:inventory_stock` | inventory_stock | Menu Browser | Sin filtro | ALL |
| `delivery_orders_$businessId` | orders, order_items, payments | Delivery view | Sin filtro server-side | ALL |
| `rt:settings_zones:$businessId` | zones | Settings → Zonas y Mesas | Sin filtro | ALL |
| `rt:settings_tables:$businessId` | dining_tables | Settings → Zonas y Mesas | Sin filtro | ALL |
| `realtime:printers:$businessId` | printers | Settings → Impresoras | Sin filtro | ALL |
| `realtime:discovery_jobs:$jobId` | discovery_jobs | Settings → Test impresora | `id = $jobId` | ALL |
| `print_jobs_health:$businessId` | print_jobs, printers | Settings → Salud impresión | `business_id = $businessId` | ALL |
| KDS channel (kitchen_viewmodel) | order_items | KDS | ⚠️ verificar | ALL |

**Ubicaciones de suscripción:**

- [lib/data/repositories/zones_repository.dart:615-655](lib/data/repositories/zones_repository.dart)
- [lib/presentation/sales/viewmodel/sales_viewmodel.dart:2331-2405](lib/presentation/sales/viewmodel/sales_viewmodel.dart) — `_subscribeToOrderUpdates(orderId)`
- [lib/presentation/sales/viewmodel/menu_browser_viewmodel.dart:266-291](lib/presentation/sales/viewmodel/menu_browser_viewmodel.dart) — debounce 500ms
- [lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart:236-339](lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart)
- [lib/presentation/sales/viewmodel/delivery_viewmodel.dart:91-104](lib/presentation/sales/viewmodel/delivery_viewmodel.dart)
- [lib/presentation/settings/.../zones_tables/.../zones_tables_viewmodel.dart:672-688](lib/presentation/settings/more%20settings/system%20settings/zones_tables/viewmodel/zones_tables_viewmodel.dart)
- [lib/presentation/settings/.../printing/printers/viewmodel/printers_viewmodel.dart:1334-1350](lib/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart)
- [lib/presentation/kds/viewmodel/kds_viewmodel.dart:128-131](lib/presentation/kds/viewmodel/kds_viewmodel.dart)

### 8.2 Publication de Realtime

Tablas confirmadas en publication (vía migraciones encontradas):

- `inventory_stock`, `menu_items` ([mig 20260517_0003_realtime_inventory.sql](supabase/migrations/20260517_0003_realtime_inventory.sql)) — agregadas explícitamente con `REPLICA IDENTITY FULL`.

⚠️ **PENDIENTE DE VERIFICAR** en producción para el resto (orders, order_items, payments, table_sessions, dining_tables, zones, printers, print_jobs, discovery_jobs). El código se suscribe asumiendo que están en la publication, pero no hay migración que lo agregue explícitamente en este repo. Habría que consultar `pg_publication_tables` directamente en la BD productiva.

### 8.3 Manejo de desconexión

**No hay reconnect explícito en los callbacks.**

```dart
// Patrón típico — ej. zones_repository.dart:615-655
final ch = sb.channel('zones:status')
  ..onPostgresChanges(...)
  ..subscribe();
// Sin onError, sin onClose, sin retry
```

Comportamiento observado:
- Al desconectar red, el cliente SDK mantiene la suscripción "viva" internamente.
- **Los eventos nuevos se pierden** hasta reconexión.
- `dispose()` llama `.unsubscribe()` explícitamente (limpieza al cambiar pantalla).
- Al reabrir la pantalla, se re-suscribe desde cero.

`ConnectivityService` ([lib/core/network/connectivity_service.dart](lib/core/network/connectivity_service.dart)) **NO se integra con los channels de Realtime** — no reinicia suscripciones cuando vuelve la conexión.

### 8.4 Brechas offline

- **Sin reconnect automático:** eventos perdidos en cortes de red.
- **Sin sincronización inicial post-reconnect:** la suscripción solo trae eventos nuevos. Los cambios que ocurrieron mientras estabas desconectado se pierden hasta que la pantalla se recargue manualmente.
- **No hay polling fallback** para el caso "Realtime no funciona pero las queries sí".

---

## 9. Infraestructura relevante para offline

⚠️ **Esta sección depende mayormente de configuración fuera del repo Flutter (Coolify/Traefik/GoTrue env vars). Marcamos todo lo no verificable.**

### 9.1 Latencia us-east-1 → RD

⚠️ **PENDIENTE DE VERIFICAR.** El solicitante mencionó que ya tiene medidos los valores. No están documentados en el repo.

### 9.2 JWT TTL

⚠️ **PENDIENTE DE VERIFICAR.** El solicitante mencionó **7 días** (`GOTRUE_JWT_EXP = 604800`). Configurado en Coolify, no en el repo.

Impacto en sesiones largas sin red:
- Si el JWT vence y no hay refresh: tras 3 reintentos, si hay refreshToken se preserva la sesión local; si no, logout.
- Con 7 días, un cierre nocturno + reapertura matutina no se ve afectado.

### 9.3 Refresh token TTL y rotación

⚠️ **PENDIENTE.** Vars `GOTRUE_REFRESH_TOKEN_ROTATION_*` en Coolify.

### 9.4 Coolify / Traefik

⚠️ **PENDIENTE.** Habría que verificar:
- `idle_timeout` del reverse proxy (Traefik default es 90s — esto afecta cuánto tiempo puede una conexión Realtime quedar abierta sin actividad).
- `max_request_size` (afecta uploads de imágenes de productos).
- TLS cert renewal (Let's Encrypt típicamente con renovación automática).
- Cualquier rate limiting en el front-door.

### 9.5 URL y endpoints

- **Supabase URL:** `https://supabase.mangopos.do` (default en [env.dart:4-6](lib/env/env.dart)).
- **PostgREST:** implícito (subpath `/rest/v1/`).
- **GoTrue:** implícito (subpath `/auth/v1/`).
- **Realtime:** implícito (subpath `/realtime/v1/`).
- **Edge Functions:** implícito (subpath `/functions/v1/`).

### 9.6 Domain wildcard para cookies (web)

⚠️ **PENDIENTE DE CONFIRMAR EN PRODUCCIÓN.** El código asume `.mangopos.do` ([cookie_local_storage.dart:54-56](lib/core/network/cookie_local_storage.dart)). Esto solo aplica al build web.

---

## 10. Riesgos y brechas conocidas para offline

Priorizadas por impacto en la operación de venta:

### Críticas (bloquean venta sin red)

1. **Cobro offline imposible.** `fn_process_payment_v3` no se encola en `OfflinePosService`. Sin red, el cajero no puede facturar.
2. **NCF requiere red.** No hay rangos pre-asignados al cliente. La emisión del documento fiscal corre como trigger post-payment.
3. **Apertura y cierre de caja online.** Si la red cae justo al inicio del turno o justo al cierre, el cajero queda bloqueado.
4. **Validaciones de permiso/rol requieren `fn_user_effective_permissions` online** (con fallback a presets, pero los presets pueden no representar la realidad).
5. **PIN de empleado 100% online.** Para multimesero, cada PIN entry pega Supabase.

### Altas (degradan experiencia)

6. **Realtime sin reconexión automática.** Eventos perdidos durante un corte. La pantalla muestra info stale.
7. **Sin sincronización post-reconnect** de los cambios que ocurrieron mientras se estaba offline.
8. **Descuentos y cortesías no se encolan** — `fn_update_item_discount*` falla sin red.
9. **Apertura de mesa (`fn_open_table`) no se encola** — el cajero no puede empezar nuevas mesas sin red, solo agregar items a mesas ya abiertas.
10. **Inventario: descuento de stock al enviar a cocina** se hace en backend. Si la acción se encola, el stock no baja hasta sincronizar — riesgo de overselling local.

### Medias

11. **Login sin red:** primera vez en un dispositivo nuevo es imposible. JWT cacheado sobrevive ~7 días (asumido).
12. **Refresh token con 3 reintentos:** si los 3 fallan y aún hay refreshToken, preserva sesión; si no, logout abrupto.
13. **`DatabaseOperationWrapper` (timeout + retry) implementado pero huérfano** — los repos no lo usan. Errores transitorios de red en queries puntuales no se reintentan.
14. **Edge function `emit-document` síncrono** — si falla, ticket sale como "Pendiente DGII" y queda para cron. Sin red, el ticket también sale como pendiente (al menos no rompe).
15. **Audit logs (cierre, reconteo, etc.) son fire-and-forget** — si fallan, no se reintentan (best-effort).

### Bajas

16. **`SessionState` solo en memoria** — un kill de la app pierde el state hasta el siguiente `restoreFromSupabaseSession()`.
17. **Catálogo offline puede quedar stale** — si un producto se renombra/elimina cuando el cliente está offline, el snapshot local sigue con el dato viejo hasta sincronizar.
18. **No hay banner global "sin conexión"** en la UI. El cajero solo se entera cuando una operación falla.

---

## 11. Apéndices

### 11.1 Tablas SQL relevantes

Extracto de [supabase/schema.sql](supabase/schema.sql). Solo columnas críticas; ver el archivo para constraints y RLS completos.

**Auth y membresías**

```sql
-- gestionada por GoTrue
auth.users (id uuid PK, email, ...)

public.profiles (
  id uuid PK references auth.users(id),
  full_name text,
  ...
)

public.businesses (
  id uuid PK,
  name text,
  owner_id uuid references auth.users(id),
  domain text,
  created_at timestamptz
)

public.user_businesses (
  user_id uuid references auth.users(id),
  business_id uuid references businesses(id),
  role text (owner|admin|cashier|waiter|kitchen|delivery),
  PRIMARY KEY (user_id, business_id)
)

public.employees (
  id uuid PK,
  business_id uuid references businesses(id),
  user_id uuid NULL references auth.users(id),
  name text,
  pin text,
  status text (active|inactive),
  ...
)
```

**Ventas**

```sql
public.zones (id, business_id, name, position, is_active)
public.dining_tables (id, zone_id, name, state enum (available|occupied|reserved), ...)
public.table_sessions (
  id uuid PK,
  business_id uuid,
  table_id uuid NULL,
  origin text (dine_in|manual|quick_sale|delivery|self_service),
  waiter_user_id uuid NULL,
  opened_at, closed_at
)
public.orders (
  id uuid PK,
  session_id uuid references table_sessions,
  status enum (open|paid|canceled|...),
  status_ext enum (open|sent_to_kitchen|partially_paid|paid|void),
  subtotal, tax, service_fee, discounts, total,
  origin, customer_id, customer_name, customer_tax_id, fiscal_type,
  created_at, closed_at
)
public.order_checks (
  id uuid PK,
  order_id, position, label,
  customer_id, customer_name, customer_tax_id, fiscal_type,
  is_closed boolean
)
public.order_items (
  id uuid PK,
  order_id, check_id, product_id, product_name,
  quantity, qty, unit_price, tax_mode, tax_rate, original_tax_rate,
  is_takeout boolean, notes, status (draft|pending|preparing|ready|paid|void),
  subtotal, tax, discounts, total,
  print_area_code,
  ...
)
public.order_item_tax_lines (
  id, order_item_id, tax_id, tax_name, tax_rate, amount
)
public.payments (
  id uuid PK,
  order_id, check_id, payment_method_id,
  amount, change_amount,
  ncf_number, ncf_type, fiscal_document_id,
  status (completed|pending|...),
  split_sequence smallint,
  bank_account_id,
  created_at,
  UNIQUE (order_id, COALESCE(check_id,..), payment_method_id, split_sequence) WHERE status='completed'
)
```

**Caja**

```sql
public.cash_registers (id, business_id, name, ...)
public.cash_register_sessions (
  id uuid PK,
  cash_register_id, user_id, device_id, device_name,
  status (open|closed),
  opened_at, closed_at,
  start_amount, end_amount, notes,
  close_mode_used (blind|detailed) NULL
)
public.cash_count_blind (
  id uuid PK,
  cash_register_session_id, business_id,
  cash_amount, card_amount, transfer_amount,
  denominations jsonb,
  opening_float, supervisor_note,
  signed_at, signed_by_user_id,
  attempt_number int (1 o 2),
  UNIQUE (cash_register_session_id, attempt_number)
)
public.cash_transactions (id, session_id, type, amount, reason, ...)
```

**Productos / catálogo / inventario**

```sql
public.categories (id, business_id, name, position, is_active)
public.menus (id, business_id, name, ...)
public.menu_items (
  id uuid PK,
  business_id, category_id, name, price,
  tax_mode (inclusive|exclusive), sku, barcode, cost,
  has_variants, is_active, has_prep,
  is_inventory_tracked boolean,
  allow_negative_sale boolean,
  auto_disabled boolean,
  print_area_code,
  kitchen_banner_dine_in, kitchen_banner_takeout (vía business_settings, no aquí)
)
public.menu_item_links (item_id, menu_id, position)
public.menu_item_taxes (item_id, tax_id)
public.taxes (id, business_id, name, rate, is_active, is_service_fee, apply_on_*)
public.inventory_items, inventory_stock, inventory_movements, warehouses, recipes, recipe_ingredients
v_menu_items_stock (vista para badge de stock)
```

**Fiscal**

```sql
public.ncf_sequences (
  id, business_id, ncf_type, prefix, range_start, range_end, current_number,
  is_active, expiration_date
)
public.fiscal_documents (
  id uuid PK,
  order_id, check_id, payment_id, business_id,
  ncf_number, ncf_type, amount,
  customer_id, customer_rnc,
  status (active|cancelled|revoked),
  is_electronic boolean,
  security_code, signature, issued_at,
  ...
)
public.fiscal_settings (business_id, ...) -- config de RNC, razón social, etc.
```

**Impresión**

```sql
public.printers (id, business_id, name, type (network|usb|bluetooth), ip_address, port, mac, device_path, host_device_id, is_active, online, last_seen)
public.print_areas (id, business_id, code, name)
public.print_area_printers (area_id, printer_id, prints_orders, prints_prebills, prints_receipts, enabled)
public.print_jobs (id, business_id, printer_id, payload, status, attempts, created_at, ...)
```

**Settings**

```sql
public.business_settings (
  business_id PK,
  cash_close_mode, receipt_item_display_mode,
  inventory_mode (none|basic|advanced),
  kitchen_enabled, barcode_enabled,
  sales_mode_table_enabled, ..._manual_enabled, ..._quick_enabled, ..._delivery_enabled,
  multimesero_enabled, transfers_require_approval,
  kitchen_banner_dine_in, kitchen_banner_takeout,
  allow_recount,
  agent_url
)
```

**Auditoría**

```sql
public.audit_logs (
  id, business_id, user_id, action, reason, ref_table, ref_id, created_at
)
```

### 11.2 RPCs de Postgres usadas por la app

Ver §5.1 para tabla completa con file:line. Resumen agrupado:

**Sesión / negocio**
- `fn_user_effective_permissions(p_user_id, p_business_id)`
- `user_has_business_access(_user_id, _business_id)`
- `user_business_role(_user_id, _business_id)`
- `has_business_role(_user_id, _business_id, _roles[])`

**Caja**
- `fn_open_cash_session`
- `fn_close_cash_session`
- `fn_get_cash_session_summary`
- `mark_session_close_mode` (via UPDATE, no RPC)

**Ventas — orden y items**
- `fn_open_table`, `fn_open_manual_or_quick`, `fn_open_delivery_order`
- `fn_add_item_from_menu`
- `fn_update_item_qty`, `fn_update_item_notes`, `fn_update_item_details`, `fn_update_item_discount`, `fn_update_item_discount_and_notes`
- `fn_delete_item`, `fn_toggle_item_takeout`
- `fn_move_item_to_check`, `fn_move_items_to_check_batch`
- `fn_create_split_bill`, `fn_split_items_equally`, `fn_explode_items_to_units`, `fn_consolidate_order_to_integer`
- `fn_get_order_bundle`
- `fn_close_order_and_table`
- `fn_assign_customer_to_session`, `fn_set_check_customer_and_ncf`
- `fn_assign_manual_order_to_table`
- `fn_mark_order_takeout`
- `fn_confirm_order_to_kitchen`

**Pago / fiscal**
- `fn_process_payment_v3`
- `generate_ncf`
- `create_fiscal_document`
- Edge function `emit-document` (e-CF síncrono)

**Inventario**
- `consume_inventory_from_order` (trigger function — reescrito 20260517_0002 para ser reconciliadora)
- `fn_recompute_menu_items_availability` (trigger — respeta `allow_negative_sale`)
- `fn_menu_item_set_inventory_tracked`
- `fn_sync_inventory_stock_on_movement` (trigger)
- `fn_order_items_reconcile_inventory` (trigger)

### 11.3 Dependencias relevantes (pubspec.yaml)

Extracto de [pubspec.yaml](pubspec.yaml):

```yaml
# Versión actual: 1.0.0+32
# SDK: ^3.8.1

dependencies:
  # Core
  flutter_riverpod: ^2.6.1
  supabase_flutter: ^2.10.0
  go_router: ^16.2.1
  intl: ^0.19.0
  uuid: ^4.5.1
  equatable: ^2.0.7
  decimal: ^3.2.4
  crypto: ^3.0.3

  # Storage (sin BD relacional)
  shared_preferences: ^2.2.2
  path_provider: ^2.1.3

  # Connectivity
  connectivity_plus: ^6.0.0
  multicast_dns: ^0.3.2
  network_info_plus: ^7.0.0

  # HTTP
  http: ^1.6.0
  web_socket_channel: ^3.0.3
  shelf: ^1.4.2
  shelf_router: ^1.1.4

  # Bluetooth / Impresión
  flutter_blue_plus: '>=1.32.4 <1.35.0'
  flutter_blue_plus_windows: ^1.26.1
  universal_ble: ^0.21.1
  flutter_usb_printer: ^0.1.0+1
  esc_pos_utils_plus: ^2.0.4
  printing: ^5.14.2

  # Otros
  cached_network_image: ^3.4.1  # cache de imágenes
  process_run: ^1.3.0
  auto_updater: ^1.0.0
  window_manager: ^0.5.1
  permission_handler: ^12.0.1
```

**Notas clave:**
- ❌ No hay `sqflite`, `drift`, `isar`, `hive`, `sembast`.
- ❌ No hay `flutter_secure_storage`.
- ❌ No hay `internet_connection_checker_plus` (solo `connectivity_plus`).
- ✅ `cached_network_image` para imágenes de productos.
- ✅ `shared_preferences` es el único storage local clave-valor.

---

## 12. Preguntas abiertas

Items que **no pude verificar en el repo** y necesito confirmación antes del PRD de offline-first:

### Infraestructura (Coolify / GoTrue)

1. **JWT `GOTRUE_JWT_EXP`** — ¿7 días confirmado? ¿O distinto?
2. **Refresh token TTL** — `GOTRUE_REFRESH_TOKEN_ROTATION_*`. ¿Rota? ¿Cada cuánto?
3. **Latencia us-east-1 → RD** — ¿valores típicos medidos? (p50, p95).
4. **Coolify/Traefik:**
   - `idle_timeout` del reverse proxy (afecta cuán "vivas" se mantienen las conexiones de Realtime).
   - Rate limits si los hay.
   - `max_request_size`.
5. **Backups y RTO de Supabase self-hosted** — ¿pueden los terminales sobrevivir 30+ minutos sin backend mientras se recupera?
6. **Estado de tablas en `supabase_realtime` publication** — solo confirmé `inventory_stock` y `menu_items` vía migración. Las demás (orders, order_items, payments, dining_tables, etc.) **funcionan en Realtime en producción**, pero no encuentro migración que las agregue. Necesito que verifiques con:
   ```sql
   SELECT pubname, schemaname, tablename FROM pg_publication_tables
   WHERE pubname = 'supabase_realtime' ORDER BY tablename;
   ```

### Backend (Edge functions y trabajos en cola)

7. **Edge function `emit-document`** — ¿código fuente disponible? ¿qué hace exactamente y qué timeouts maneja?
8. **Cron de respaldo de emisión fiscal** — mencionado en código como "~60s". ¿Configurado vía Supabase Functions, pg_cron, o externo? ¿Catch-up de docs pendientes funciona offline-then-online?

### Decisiones de producto

9. **¿Cuál es el comportamiento esperado del cobro sin red?**
   - Opción A: bloquear cobro hasta recuperar red.
   - Opción B: cobrar localmente sin NCF (riesgo fiscal).
   - Opción C: cobrar con NCF de un rango pre-asignado al terminal.
   - Esta decisión guía gran parte del PRD offline.

10. **¿Apertura de caja offline aceptable?** Si sí, ¿cómo se conciliarían dos terminales que abrieron la misma caja al mismo tiempo offline?

11. **¿Reportes Z offline aceptables?** El cálculo es client-side feasible si tenemos todas las transacciones; pero sin red no se puede confirmar que están todas.

12. **¿Sincronización de inventario offline:** ¿se permite vender en negativo offline aunque no haya `allow_negative_sale=true`? Hoy se valida client-side y server-side.

### Multi-dispositivo

13. **¿Cuántos terminales típicos por local?** Esto afecta el diseño del mecanismo de sincronización.

14. **¿Hay un terminal "líder" en cada local (e.g. la PC de caja con agente Node.js) que pueda actuar como hub local de coordinación?** O todos son peers iguales.

15. **¿La LAN del local es confiable?** Si la LAN cae junto con internet, los terminales no pueden ni siquiera coordinarse entre sí.

### Auditoría y compliance

16. **DGII — requisitos exactos de fiscalidad offline.** ¿Permite RD que un comercio facture sin NCF y emita después? ¿O todo debe ser online en tiempo real?

17. **Trazabilidad de cambios offline** — si dos terminales editan la misma orden offline y luego sincronizan, ¿qué política de conflict resolution se espera?

18. **Conteo ciego sin red:** si el cierre se hace offline, ¿la firma del cajero queda registrada localmente y sube cuando vuelve la red? ¿O directamente no se permite cerrar sin red?

---

**Fin del PRD AS-IS.**

Este documento debería revisarse y validarse con el equipo de producto/operaciones antes de pasar al PRD de migración a offline-first. Las preguntas abiertas en §12 son los próximos puntos a resolver.
