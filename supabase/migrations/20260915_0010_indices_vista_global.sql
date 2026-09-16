-- ===========================================================================
-- 20260915_0010 — Índices para la Vista Global de la consola de operador
--
-- POR QUÉ
-- `get_platform_overview()` (la pantalla principal del panel) arma diez
-- agregados por negocio en cada carga. Medido sobre la base real:
--
--   payments           149.709 filas   84 MB
--   fiscal_documents   148.217 filas   92 MB
--   table_sessions     190.681 filas   58 MB
--   businesses              71 filas
--
-- Faltaban dos índices y eso obligaba a leer tablas enteras:
--
--   * `fd_today` filtra fiscal_documents por `issued_at` + `status='active'`,
--     y no existía NINGÚN índice por `issued_at` (los que hay son por
--     `created_at`): leía los 92 MB completos en cada carga.
--   * `last_payment` y `rev_today` filtran payments por `status='completed'`.
--     El índice existente `(business_id, created_at)` no incluye `status`,
--     así que había que ir a la tabla a verificar fila por fila.
--
-- Los índices son parciales (solo las filas que estas consultas miran), así
-- que ocupan una fracción de la tabla y no estorban a la operación del POS.
--
-- OJO AL APLICARLA
-- `create index` bloquea las ESCRITURAS de esa tabla mientras se construye
-- (segundos, a estos tamaños). Conviene correrla fuera del horario pico.
-- Si preferís cero bloqueo, ver la variante `concurrently` al pie.
--
-- Idempotente (`if not exists`). Rollback:
-- 20260915_0010_indices_vista_global_ROLLBACK.sql
-- ===========================================================================

-- Pagos completados por negocio, del más nuevo al más viejo.
-- Sirve a `last_payment` (última actividad) y a `rev_today` (venta de hoy).
create index if not exists idx_payments_completed_business_created
  on public.payments (business_id, created_at desc)
  where status = 'completed';

-- Comprobantes activos por fecha de emisión: `fd_today` (NCF emitidos hoy).
create index if not exists idx_fiscal_documents_active_business_issued
  on public.fiscal_documents (business_id, issued_at desc)
  where status = 'active';

-- Mesas abiertas por negocio: `open_tables_agg`. Parcial, así que solo
-- indexa las sesiones sin cerrar (un puñado) y no las 190k históricas.
create index if not exists idx_table_sessions_open_business
  on public.table_sessions (business_id)
  where closed_at is null;

-- Trabajos de impresión de las últimas 24h: `print_agg`. La tabla es chica
-- (7k filas) pero el índice evita recorrerla entera en cada carga.
create index if not exists idx_print_jobs_created_at
  on public.print_jobs (created_at desc);

-- Que el planner use los índices nuevos desde la primera consulta.
analyze public.payments;
analyze public.fiscal_documents;
analyze public.table_sessions;
analyze public.print_jobs;

-- ---------------------------------------------------------------------------
-- VARIANTE SIN BLOQUEO (opcional)
--
-- `concurrently` no bloquea escrituras, pero NO puede correr dentro de una
-- transacción: hay que ejecutar cada línea por separado desde psql, no desde
-- el editor SQL del dashboard. Si se usa esta variante, no correr el bloque
-- de arriba.
--
--   create index concurrently if not exists idx_payments_completed_business_created
--     on public.payments (business_id, created_at desc) where status = 'completed';
--
--   create index concurrently if not exists idx_fiscal_documents_active_business_issued
--     on public.fiscal_documents (business_id, issued_at desc) where status = 'active';
--
--   create index concurrently if not exists idx_table_sessions_open_business
--     on public.table_sessions (business_id) where closed_at is null;
--
--   create index concurrently if not exists idx_print_jobs_created_at
--     on public.print_jobs (created_at desc);
-- ---------------------------------------------------------------------------
