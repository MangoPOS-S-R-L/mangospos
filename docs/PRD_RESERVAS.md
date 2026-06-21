# PRD — Módulo de Reservas para MangoPOS

> **Estado:** F1 IMPLEMENTADA en `main` (sin aplicar la migración todavía). Ver
> §11 "Estado de implementación". Add-on activado por plataforma.
> **Fecha:** 2026-06-19
> **Dueño de producto:** Cristian Gómez
> **Ámbito:** Permitir que el personal (anfitrión / cajero) **reserve una mesa
> específica para un cliente en una fecha y hora futura**, vea la agenda del día,
> y al llegar el cliente **siente la reserva** abriendo la mesa con un toque. El
> módulo reutiliza Zonas/Mesas, Clientes y el patrón Riverpod que ya tiene la app.
> **Diferenciador:** paridad con Toast/Aloha en gestión de reservas de salón,
> sin inventar arquitectura nueva.
>
> Continúa el PRD previo [PRD Zonas y Mesas](../lib/PRD%20Zonas%20y%20Mesas/PRD-Zonas-Mesas-Estado-Actual-y-Vision.md),
> que ya listaba Reservas como capacidad futura ("Reservar mesa para fecha/hora,
> libera automáticamente si no llega") y la declaraba **módulo nuevo aparte**.

---

## 0. Decisiones de alcance (cerradas con el dueño de producto)

| # | Decisión | Resolución |
|---|---|---|
| D1 | Alcance de la Fase 1 | **Solo interno.** El anfitrión/cajero crea y gestiona reservas desde la POS. **Sin** reservas online del cliente (web pública) en F1. |
| D2 | Modelo de asignación de mesa | **Mesa específica al reservar.** Cada reserva apunta a una `dining_table` concreta. Esto habilita detección de choque (doble reserva) y resaltar la mesa en el salón. |
| D3 | Conectividad | **Online (requiere internet).** Las reservas se planean con antelación desde una estación con red. **No** entran a la cola offline en F1. |
| D4 | Entregable | **Este PRD por fases**, luego implementar F0/F1. |
| D5 | Modelo de activación | **Add-on de pago controlado por la PLATAFORMA.** No viene por defecto ni el dueño lo activa solo: MangoPOS lo prende por negocio desde el panel administrativo. Implementado con la tabla `business_modules` (solo `service_role` escribe; el POS solo lee). |

### Decisiones técnicas propuestas (pendientes de tu visto bueno)

Estas las propongo yo con una recomendación; cámbialas antes de codificar si quieres.

| # | Tema | Recomendación |
|---|---|---|
| T1 | Estado visual de mesa reservada | **No** escribir `dining_tables.state = 'reserved'`. Ese campo es de **configuración/layout** (estático); una reserva es **acotada en el tiempo** (solo "reservada" cerca de su hora). Si lo mutamos, hace falta un cron que lo devuelva a `available` y se corrompe el estado real. En su lugar, el salón **deriva** "tiene reserva próxima" consultando la tabla `reservations` y pinta un **badge/borde azul** en la mesa. El valor `'reserved'` del enum queda disponible solo para un bloqueo manual futuro. |
| T2 | Detección de doble reserva | Mesa + ventana de tiempo (`reserved_for` + `duration_minutes`). La verifico en el **RPC** `fn_create_reservation` con `SELECT … FOR UPDATE` sobre las reservas activas de esa mesa, y **además** propongo un **exclusion constraint** (`btree_gist` sobre `(table_id, tstzrange)` filtrado a estados activos) como red de seguridad contra carreras. |
| T3 | Sentar la reserva | "Sentar" reutiliza **el mismo camino que abre una mesa hoy** (insertar `table_sessions` origin `dine_in`), envuelto en `fn_seat_reservation(reservation_id)`: abre la sesión, copia `people_count`/`customer_name`, enlaza `reservations.session_id` y pasa la reserva a `seated`. No se inventa flujo de cobro nuevo. |
| T4 | Cliente walk-in vs registrado | `customer_id` **opcional** (FK a `customers`) + `customer_name`/`customer_phone` **denormalizados** y obligatorios. Permite reservar sin crear cliente; botón "Guardar como cliente" crea la fila en `customers` reutilizando `CustomersRepository`. |
| T5 | Liberar si no llega | Cron opcional `fn_expire_overdue_reservations(grace_minutes)` (patrón de `fn_release_empty_tables`) marca `no_show` las reservas vencidas no sentadas. En F1 puede ser manual; el cron se activa en F1.5. |
| T6 | Zona horaria | Guardar `reserved_for` como `timestamptz`. Agrupar "el día" y comparar "hora local" usando la zona del negocio (RD = `America/Santo_Domingo`, sin DST), **igual que happy hour** ya hace para ofertas por franja. Ver [ofertas happy hour](../supabase/migrations/20260617_0001_promotions_happy_hour.sql). |
| T7 | Ubicación en el menú | Destino propio **"Reservas"** en el shell, gateado por permiso `reservas.acceso` y oculto en retail vía `requiresFeature: 'reservations'`. La ruta `/reservations` **ya existe** (hoy es placeholder). |

---

## 1. Estado actual — qué ya existe y qué falta

### Ya existe (base reutilizable, **no** hay que inventar)

- **Ruta `/reservations`** ya declarada en [routes.dart](../lib/app/router/routes.dart#L30)
  y registrada en [app_router.dart](../lib/app/router/app_router.dart#L505) como
  `_Placeholder('Tables/Reservations')`. → Solo hay que sustituir el placeholder.
- **Enum `table_state` con `'reserved'`** en [schema.sql](../supabase/schema.sql#L197)
  y en [dining_table.dart](../lib/data/models/dining_table.dart). Decidimos **no** usarlo
  para reservas con tiempo (T1), pero ahí está.
- **Zonas/Mesas completo:** `zones`, `dining_tables` (con `capacity`, geometría de
  plano), vista `v_zone_table_status`, [ZonesRepository](../lib/data/repositories/zones_repository.dart),
  [ByZoneViewModel](../lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart),
  `SalesByZoneView` y el floor map. **El salón es donde se integra el badge de reserva.**
- **Clientes:** tabla `customers` (name, legal_name, phone, email, tax_id),
  [CustomersRepository](../lib/data/repositories/customers_repository.dart) con
  búsqueda `ilike` por nombre/teléfono/RNC. → Reutilizable tal cual para enlazar/crear.
- **`table_sessions`** (origin `dine_in`/`delivery`, `people_count`, `customer_name`,
  `waiter_user_id`, `business_id`) — el destino al "sentar" la reserva.
- **Patrón de feature maduro a copiar:** modelo → `queries/*.sql` → repository →
  Riverpod `Notifier` + `State` → view. Multi-tenant por `business_id` + RLS con
  `current_user_business_ids()`. Realtime con debounce. Cache offline opcional.
- **Cron pattern:** `fn_release_empty_tables` (libera mesas vacías) — molde para
  `fn_expire_overdue_reservations`.
- **Permisos por rol:** `permissionCode` en cada destino del shell
  ([shell_destinations.dart](../lib/presentation/shell/shell_destinations.dart#L39))
  y feature flags por negocio (`requiresFeature`).

### Falta (greenfield)

- Tabla `reservations` + RLS + índices + exclusion constraint.
- RPCs: `fn_create_reservation`, `fn_update_reservation`, `fn_seat_reservation`,
  `fn_cancel_reservation`, (opcional) `fn_expire_overdue_reservations`.
- (Opcional F1.5) extender `v_zone_table_status` con `next_reservation_at`.
- Capa Flutter: modelo, queries, repository, viewmodel/state, vistas, formulario.
- Entrada de menú + permisos `reservas.*`.

---

## 2. Modelo de datos

Migración propuesta: `supabase/migrations/20260619_0001_create_reservations.sql`
(con su `_ROLLBACK.sql`).

```sql
-- Estado de la reserva (ciclo de vida)
CREATE TYPE public.reservation_status AS ENUM (
  'pending',    -- reservado por canal online, aún sin confirmar (futuro F3)
  'confirmed',  -- confirmada por el local (estado por defecto en F1 interno)
  'seated',     -- el cliente llegó y se abrió la mesa (tiene session_id)
  'completed',  -- la sesión cerró / consumo terminado
  'cancelled',  -- cancelada por el local o el cliente
  'no_show'     -- no llegó dentro del período de gracia
);

CREATE TABLE public.reservations (
  id              uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  business_id     uuid NOT NULL REFERENCES public.businesses(id),
  branch_id       uuid REFERENCES public.branches(id),         -- multi-sucursal futuro
  table_id        uuid NOT NULL REFERENCES public.dining_tables(id),
  customer_id     uuid REFERENCES public.customers(id),        -- opcional (walk-in)
  customer_name   text NOT NULL,                               -- denormalizado (obligatorio)
  customer_phone  text,
  party_size      integer NOT NULL CHECK (party_size > 0),
  reserved_for    timestamptz NOT NULL,                        -- inicio de la reserva
  duration_minutes integer NOT NULL DEFAULT 90 CHECK (duration_minutes > 0),
  status          public.reservation_status NOT NULL DEFAULT 'confirmed',
  notes           text,
  session_id      uuid REFERENCES public.table_sessions(id),   -- set al sentar
  created_by      uuid NOT NULL REFERENCES auth.users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Rango temporal materializado para el exclusion constraint
ALTER TABLE public.reservations
  ADD COLUMN time_range tstzrange
  GENERATED ALWAYS AS (
    tstzrange(reserved_for, reserved_for + (duration_minutes || ' minutes')::interval)
  ) STORED;

-- Índices de consulta típica (agenda del día por negocio, por mesa)
CREATE INDEX idx_reservations_business_day
  ON public.reservations (business_id, reserved_for)
  WHERE status IN ('pending','confirmed','seated');
CREATE INDEX idx_reservations_table
  ON public.reservations (table_id, reserved_for);
CREATE INDEX idx_reservations_customer
  ON public.reservations (customer_id);

-- Red de seguridad contra doble reserva (carreras): una mesa no puede tener
-- dos reservas ACTIVAS solapadas en el tiempo.
CREATE EXTENSION IF NOT EXISTS btree_gist;
ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_no_overlap
  EXCLUDE USING gist (
    table_id WITH =,
    time_range WITH &&
  ) WHERE (status IN ('pending','confirmed','seated'));
```

**RLS** (espejo de `customers` / `dining_tables`):

```sql
ALTER TABLE public.reservations ENABLE ROW LEVEL SECURITY;

CREATE POLICY reservations_rw ON public.reservations
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));
```

> **Nota:** el `time_range` generado vive en UTC (timestamptz). El solapamiento es
> correcto independientemente de la zona; la zona horaria solo afecta cómo
> **mostramos/agrupamos** el día en la UI (T6).

---

## 3. Backend / RPCs

Todos `SECURITY DEFINER`, validan `business_id ∈ current_user_business_ids()`.

| RPC | Qué hace |
|---|---|
| `fn_create_reservation(p_business_id, p_table_id, p_customer_id, p_customer_name, p_customer_phone, p_party_size, p_reserved_for, p_duration_minutes, p_notes)` | Valida choque (el exclusion constraint hace el trabajo duro; el RPC traduce el error a un mensaje claro "La mesa ya tiene una reserva a esa hora"). Inserta con `status='confirmed'`, `created_by = auth.uid()`. Devuelve la fila. |
| `fn_update_reservation(p_id, …)` | Edita fecha/hora/mesa/personas/notas. Revalida choque. Bloquea editar si ya está `seated`/`completed`. |
| `fn_seat_reservation(p_id)` | Abre `table_sessions` (origin `dine_in`) en `table_id` reutilizando el camino actual de abrir mesa, copia `party_size→people_count` y `customer_name`, setea `reservations.session_id` y `status='seated'`. Idempotente: si ya tiene `session_id`, devuelve esa sesión. |
| `fn_cancel_reservation(p_id, p_reason)` | `status='cancelled'`. Libera la franja (sale del filtro del constraint). |
| `fn_expire_overdue_reservations(p_grace_minutes)` *(F1.5, cron)* | Marca `no_show` las `confirmed` cuyo `reserved_for + grace < now()` sin `session_id`. |

> **Verificar antes de codificar `fn_seat_reservation`:** trazar exactamente cómo
> se inserta hoy una `table_sessions` dine-in (la pantalla de mesa lo hace; ver
> [table_order_screen.dart](../lib/presentation/sales/view/table_order_screen.dart)
> y `ZonesRepository.fetchActiveSessionId`). **Reusar** ese camino, no duplicarlo.
> Es área sensible (cashier/sesiones) — cualquier cambio se valida con cuidado.

---

## 4. Capa Flutter (espejo del patrón existente)

```
lib/data/models/reservation.dart                         # modelo + fromMap/toMap + enum status
lib/data/datasources/queries/reservations_queries.dart   # SQL/select reutilizable
lib/data/repositories/reservations_repository.dart        # CRUD + RPCs + realtime subscribe
lib/presentation/reservations/
  state/reservations_state.dart                          # estado inmutable (lista, día, filtros, loading)
  viewmodel/reservations_viewmodel.dart                  # Riverpod Notifier (load/create/seat/cancel)
  view/reservations_view.dart                            # pantalla principal (agenda del día)
  view/reservation_form.dart                             # modal crear/editar
  widgets/reservation_card.dart                          # fila/tarjeta de reserva
  widgets/table_availability_picker.dart                 # selector de mesa con disponibilidad para la franja
```

**Repository — métodos clave** (firma):

```dart
class ReservationsRepository {
  Future<List<Reservation>> fetchByDay(String businessId, DateTime localDay, {String? zoneId, ReservationStatus? status});
  Future<List<Reservation>> fetchUpcomingByTable(String businessId, {Duration window});  // para el badge del salón
  Future<Reservation> create(ReservationInput input);     // → fn_create_reservation
  Future<Reservation> update(String id, ReservationInput input);
  Future<({String sessionId})> seat(String id);           // → fn_seat_reservation
  Future<void> cancel(String id, {String? reason});
  RealtimeChannel subscribe({required String businessId, required void Function() onChange});
}
```

El `ReservationsViewModel` sigue el molde de `ByZoneViewModel`: `load(businessId, day)`,
suscripción realtime con debounce, estado por día con filtros de estado/zona.

---

## 5. UX / pantallas

### 5.1 Pantalla principal — Agenda del día (`/reservations`)

- **Selector de fecha** (hoy por defecto) + flechas día anterior/siguiente.
- **Filtros:** estado (todas / confirmadas / sentadas / canceladas) y zona.
- **Lista ordenada por hora** con tarjetas: hora, nombre cliente, # personas,
  mesa (código + zona), estado (chip de color), teléfono, notas.
- **FAB "+ Nueva reserva"**.
- Acciones por tarjeta (overflow / swipe): **Sentar**, **Editar**, **Cancelar**,
  **No llegó**, **Llamar** (tel:).
- (Opcional F1.5) toggle **lista ↔ línea de tiempo** (timeline por mesa/hora),
  reusando la idea del floor map.

### 5.2 Formulario crear/editar reserva

1. **Cliente:** buscar en `customers` (reusa búsqueda existente) **o** escribir
   nombre+teléfono walk-in. Checkbox "Guardar como cliente".
2. **Fecha y hora** (date/time pickers) + **duración** (default 90 min, editable).
3. **# de personas** (`party_size`).
4. **Mesa:** `TableAvailabilityPicker` muestra mesas por zona y marca **ocupadas
   en esa franja** (consulta de choque en vivo). Avisa (warning, no bloqueo) si
   `party_size > table.capacity` (guardrail de capacidad).
5. **Notas** (cumpleaños, silla bebé, ventana, etc.).
6. Guardar → `fn_create_reservation`; si choca, mensaje claro y sugiere otra hora/mesa.

### 5.3 Integración con el salón (F1.5)

- En `SalesByZoneView` / floor map: mesa con reserva en las próximas N horas
  muestra **badge azul "Reserva 8:30 PM · Juan (4)"** (derivado de `reservations`,
  **sin** tocar `dining_tables.state`).
- Al abrir una mesa que tiene reserva próxima → banner "Reserva de Juan a las 8:30 PM"
  con botón **"Sentar esta reserva"** (llama `fn_seat_reservation`).

---

## 6. Permisos y navegación

- Nuevos códigos de permiso: **`reservas.acceso`** (ver módulo) y
  **`reservas.gestionar`** (crear/editar/cancelar/sentar). Seguir el patrón de
  `ventas.mesas.acceso` y el editor de permisos por rol.
- Nuevo destino en [shell_destinations.dart](../lib/presentation/shell/shell_destinations.dart):
  ```dart
  ShellDestination(
    label: 'Reservas',
    route: AppRoutes.reservations,
    materialIcon: Icons.event_seat,         // o un svg dedicado
    permissionCode: 'reservas.acceso',
    requiresFeature: 'reservations',        // oculto en retail
  ),
  ```
  Añadir `case 'reservations':` en `isDestinationFeatureEnabled` (default según
  el flag del negocio; restaurantes = on).
- Reemplazar el `_Placeholder('Tables/Reservations')` por `ReservationsView`.

---

## 7. Fases

| Fase | Contenido | Entregable |
|---|---|---|
| **F0 — Cimientos** | Migración `reservations` (tabla + enum + RLS + índices + exclusion constraint) y rollback. Scaffolding del módulo Flutter (carpetas, modelo, repository, viewmodel vacíos). Permisos `reservas.*` y entrada de menú (detrás de feature flag). | Migración aplicada en dev; ruta deja de ser placeholder. |
| **F1 — Gestión interna (núcleo)** | `fn_create/update/cancel_reservation`, `fn_seat_reservation`. Agenda del día (lista + filtros), formulario crear/editar con selector de mesa y detección de choque, acción **Sentar** (abre mesa). | El anfitrión opera reservas de punta a punta desde la POS. |
| **F1.5 — Salón + automatización** | Badge de reserva próxima en el floor map (extender `v_zone_table_status` o consulta aparte), realtime de `reservations`, cron `fn_expire_overdue_reservations` (no-show automático), banner "Sentar reserva" desde la mesa. | Reservas visibles en el salón y se liberan solas si no llegan. |
| **F2 — Fuera de alcance ahora** | Recordatorios al cliente (WhatsApp/SMS/email), depósitos/prepago (vía Azul), reserva por tamaño de grupo / sin mesa, lista de espera (waitlist). | — |
| **F3 — Fuera de alcance ahora** | **Reservas online del cliente** (web/link público, anti-spam, confirmación). Módulo nuevo grande. | — |

---

## 8. Riesgos y áreas sensibles

- **Salón / floor map** es área sensible (CLAUDE.md). El badge de reserva debe ser
  **aditivo** (overlay derivado), sin alterar la lógica de estado de mesa existente.
- **Sentar = abrir sesión** toca el flujo cashier/sesiones. Reutilizar el camino
  actual y cubrir con pruebas; no duplicar lógica de apertura de mesa.
- **Carrera de doble reserva:** mitigada por el `EXCLUDE` constraint (la validación
  en RPC es para el mensaje amigable, no la única defensa).
- **Zona horaria:** agrupar "el día" mal lleva a reservas que aparecen en el día
  equivocado. Usar zona del negocio como en happy hour; no `DateTime.now()` naïve.
- **`btree_gist`** debe existir en el Postgres self-hosted (Hostinger). Verificar
  `CREATE EXTENSION` permitido; si no, caer al check transaccional en el RPC.
- **Online-first (D3):** sin red, el módulo se deshabilita con aviso (no cola
  offline en F1). Coherente con el roadmap, pero documentarlo en la UI.

---

## 9. Preguntas abiertas

| # | Pregunta | Estado |
|---|---|---|
| P1 | ¿Duración por defecto 90 min, o configurable por negocio? | Propongo 90, configurable luego. |
| P2 | ¿`reservas.gestionar` separado de `reservas.acceso`, o un solo permiso en F1? | Propongo dos; confirmar. |
| P3 | ¿Zona horaria del negocio fija a RD o configurable (multi-país)? | Reusar lo que decida happy hour. |
| P4 | ¿Período de gracia para no-show (cron F1.5)? | Propongo 20 min, configurable. |
| P5 | ¿El badge de reserva se calcula extendiendo `v_zone_table_status` o con consulta aparte (menos riesgo sobre la vista)? | Decidir en F1.5. |

---

## 10. Resumen para arrancar (F0)

1. Crear `supabase/migrations/20260619_0001_create_reservations.sql` (+ rollback).
2. Crear `lib/data/models/reservation.dart`, repository y viewmodel vacíos.
3. Sustituir el placeholder de `/reservations` por `ReservationsView` mínima.
4. Añadir permisos `reservas.*` y el destino "Reservas" (con `requiresFeature`).
5. Aplicar la migración en dev y verificar RLS + exclusion constraint con datos de prueba.

---

## 11. Estado de implementación (2026-06-19)

**F0 + F1 implementadas y en `main`** (analyze limpio, 9 tests verdes). **Falta
SOLO aplicar la migración** y, del lado del panel administrativo, exponer el
botón que active el add-on.

### Activación (add-on de plataforma) — D5

- Tabla **`business_modules`** `(business_id, module, enabled, …)`. RLS: el
  negocio solo **lee**; las escrituras son **service_role** (panel
  administrativo). El dueño NO puede auto-activarse.
- RPC **`fn_set_business_module(business_id, module, enabled, …)`** — solo
  `service_role`. Al activar `'reservations'` **siembra** los permisos
  `reservas.acceso`/`reservas.gestionar` a owner/admin/manager de ese negocio.
  → El panel administrativo solo necesita llamar:
  `select fn_set_business_module('<business_id>', 'reservations', true);`
- El POS lee con `BusinessModulesRepository` + `enabledModulesProvider`; el shell
  oculta el destino "Reservas" salvo que el módulo esté activo **y** el rol tenga
  `reservas.acceso` (doble gate: plataforma + rol).

### Construido

| Capa | Archivos |
|---|---|
| BD | `supabase/migrations/20260619_0001_reservations_module.sql` (+ `_ROLLBACK`): `business_modules`, `reservations` (+ `time_range` generado + EXCLUDE `btree_gist`), RPCs `fn_create/update/seat/cancel/expire_overdue_reservations`, `fn_business_module_enabled`, `fn_set_business_module`, permisos. |
| Data | `data/models/reservation.dart`, `data/datasources/queries/reservations_queries.dart`, `data/repositories/reservations_repository.dart`, `data/repositories/business_modules_repository.dart`, `domain/repositories/i_reservations_repository.dart` |
| Estado | `core/business/business_modules_provider.dart` (`enabledModulesProvider`, `watchEnabledModules`) |
| UI | `presentation/reservations/` (state, viewmodel, `reservations_view.dart` agenda del día, `reservation_form.dart` crear/editar + buscar cliente, `widgets/reservation_card.dart`) |
| Wiring | `shell_destinations.dart` (`requiresModule` + destino Reservas), filtro en `main_shell`/`mobile_shell`, ruta real en `app_router.dart`, `route_permissions.dart`, `access_control_catalog.dart` |
| Tests | `test/reservations/reservation_model_test.dart` (parsing, estados, filtro) |

### Pendiente

1. **Aplicar la migración** en dev/prod y verificar EXCLUDE + RLS con datos de
   prueba. (Recordar que la BD viva diverge del repo — `pg_get_functiondef` de
   `fn_open_table` antes, está intacto.)
2. **Panel administrativo:** botón "Activar Reservas" por negocio que llame
   `fn_set_business_module`. (Repo separado `mango-dashboard`; no tocado aquí.)
3. **F1.5** (no incluido, toca el floor map sensible): badge de reserva próxima
   en el salón, cron `fn_expire_overdue_reservations` (no-show automático),
   banner "Sentar reserva" desde la mesa, y pre-marcado de disponibilidad en el
   selector de mesa (hoy el choque lo atrapa el EXCLUDE → mensaje amigable).
