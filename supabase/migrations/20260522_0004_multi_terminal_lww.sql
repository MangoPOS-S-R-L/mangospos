-- 20260522_0004_multi_terminal_lww.sql
-- Fase 5 — Política Multi-Terminal Last-Write-Wins (LWW).
--
-- Contexto:
--   El POS soporta múltiples terminales del mismo business operando en
--   paralelo (cajero principal + cocina + barra + tabletas de mesero) y
--   ahora también soporta cola offline (Fase 3/4). Cuando dos terminales
--   actúan sobre la misma orden/check/item, hoy NO hay registro de
--   "última actualización" en las tablas core de POS:
--
--     orders, order_items, order_checks, cash_register_sessions
--
--   La política decidida es LWW: la última escritura que llega al server
--   gana. El orden cronológico real lo garantizan dos cosas:
--     1. La cola offline es FIFO con `queued_at` (replay en orden).
--     2. PostgreSQL serializa los writes con sus locks naturales.
--
--   Esta migración NO implementa comparación de timestamps server-side
--   (eso sería invasivo en cada RPC). Solo deja **observabilidad**:
--   cada UPDATE estampa `updated_at` para que reports/auditoría puedan
--   detectar drift, doble-escritura, o operaciones encoladas que llegan
--   tarde. Sin esto, el operador no puede saber si una orden cerrada
--   "ayer" fue realmente cerrada ayer o fue un replay tardío hoy.
--
-- Cambios:
--   1. ALTER TABLE … ADD COLUMN updated_at timestamptz default now() en
--      las 4 tablas core POS (idempotente: IF NOT EXISTS).
--   2. CREATE TRIGGER set_<tabla>_updated_at BEFORE UPDATE usando el
--      helper público `trigger_set_updated_at()` (ya existe, lo usan
--      businesses, customers, menu_items, etc.).
--   3. Backfill: las filas existentes quedan con updated_at = created_at
--      (cuando aplica) o now() (cuando no hay created_at, como
--      order_checks).
--
-- Compat:
--   - Las columnas nuevas son nullables con DEFAULT, no rompen INSERTs
--     existentes ni SELECTs.
--   - El trigger es BEFORE UPDATE: no cambia el output del INSERT
--     original.
--   - Re-ejecutable: IF NOT EXISTS en columnas, OR REPLACE en triggers.
--
-- Rollback: migración separada drop column + drop trigger.

begin;

-- ---------------------------------------------------------------------------
-- 1. orders
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists updated_at timestamptz default now();

update public.orders
  set updated_at = coalesce(closed_at, created_at, now())
  where updated_at is null;

create or replace trigger set_orders_updated_at
  before update on public.orders
  for each row
  execute function public.trigger_set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. order_items
-- ---------------------------------------------------------------------------
alter table public.order_items
  add column if not exists updated_at timestamptz default now();

update public.order_items
  set updated_at = coalesce(created_at, now())
  where updated_at is null;

create or replace trigger set_order_items_updated_at
  before update on public.order_items
  for each row
  execute function public.trigger_set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. order_checks
-- ---------------------------------------------------------------------------
-- order_checks históricamente no tiene created_at. Solo backfill con now().
alter table public.order_checks
  add column if not exists updated_at timestamptz default now();

update public.order_checks
  set updated_at = coalesce(closed_at, now())
  where updated_at is null;

create or replace trigger set_order_checks_updated_at
  before update on public.order_checks
  for each row
  execute function public.trigger_set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. cash_register_sessions
-- ---------------------------------------------------------------------------
alter table public.cash_register_sessions
  add column if not exists updated_at timestamptz default now();

update public.cash_register_sessions
  set updated_at = coalesce(closed_at, opened_at, now())
  where updated_at is null;

create or replace trigger set_cash_register_sessions_updated_at
  before update on public.cash_register_sessions
  for each row
  execute function public.trigger_set_updated_at();

commit;

-- ---------------------------------------------------------------------------
-- Notas operacionales (no son SQL, sirven de doc dentro del archivo):
--
-- Convención cliente:
--   Cada mutation encolada en offline_pos_service.dart YA lleva un
--   timestamp `queued_at` o `paid_at`/`occurred_at` según corresponda.
--   El replay las procesa en orden FIFO. La columna updated_at server-
--   side queda como "cuándo llegó al server", útil para distinguir un
--   replay tardío de una operación online.
--
-- Drift detection:
--   Si necesitas detectar drift desde un cliente que estuvo offline:
--
--     select id, created_at, updated_at,
--            updated_at - created_at as latency
--     from orders
--     where business_id = $1
--       and updated_at > $last_seen_at;
--
--   Eso te lista las órdenes que fueron tocadas (creadas o updates) en
--   el server después del último checkpoint del cliente — base para un
--   patrón incremental sync más adelante.
-- ---------------------------------------------------------------------------
