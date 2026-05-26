-- =====================================================================
-- Migration: agregar estado visual "precuenta impresa" a la vista de mesas
-- =====================================================================
-- Motivación: cuando el cajero imprime una precuenta, queremos que la
-- mesa cambie a color azul en la pantalla "Ventas por zona" para que
-- todos los terminales (caja, meseros, KDS) sepan que el cliente ya
-- pidió la cuenta. El enum `TableStatus.pagando` ya existe en el
-- cliente Flutter y mapea a azul — solo faltaba alguien que escribiera
-- `'paying'` al campo `status` de la vista.
--
-- Cambios:
--   1) Nueva columna `table_sessions.precheck_printed_at timestamptz`
--      (nullable). Se setea al imprimir precuenta, se ignora al cerrar
--      la sesión (se va junto con `closed_at`).
--   2) Vista `v_zone_table_status` recreada para exponer una columna
--      `status` derivada: 'paying' si hay timestamp de precuenta y la
--      sesión sigue abierta; NULL en otro caso (el cliente lo trata
--      como "ocupado" — naranja).
--
-- Cliente: el mapping ya existe en
-- lib/presentation/sales/view/sales_by_zone_view.dart:1088 y
-- lib/data/models/table_status.dart:38 — no requiere cambios extra
-- para que el azul aparezca cuando la vista devuelve 'paying'.
-- =====================================================================

-- 1) Agregar columna idempotente
alter table public.table_sessions
  add column if not exists precheck_printed_at timestamptz null;

comment on column public.table_sessions.precheck_printed_at is
  'Timestamp en que se imprimió la precuenta de esta sesión. Pinta la mesa de azul en v_zone_table_status mientras la sesión no esté cerrada. NULL = sin precuenta impresa todavía.';

-- 2) Recrear vista incluyendo columna `status`.
-- IMPORTANTE: Postgres `create or replace view` exige columnas idénticas
-- en orden y tipo. La vista deployada puede haber divergido del
-- schema-as-code (migraciones acumuladas, fixes manuales), así que
-- dropeamos y recreamos para garantizar la forma exacta. Si el DROP
-- falla con "other objects depend", cambia a `DROP VIEW ... CASCADE`
-- (chequea antes con `\d+ public.v_zone_table_status` quién depende).
drop view if exists public.v_zone_table_status;

create view public.v_zone_table_status as
select
  t.id              as table_id,
  z.id              as zone_id,
  z.name            as zone_name,
  z.business_id,
  t.code,
  t.label,
  t.shape,
  t.capacity,
  t.state,
  s.id              as session_id,
  s.opened_by,
  s.opened_at,
  case when s.opened_at is not null and s.closed_at is null
       then extract(epoch from (now() - s.opened_at))::int / 60
       else null end as minutes_open,
  coalesce((select count(*) from public.orders o where o.session_id = s.id),0) as orders_count,
  case
    when s.precheck_printed_at is not null and s.closed_at is null then 'paying'
    else null
  end               as status
from public.dining_tables t
join public.zones z on z.id = t.zone_id
left join lateral (
  select * from public.table_sessions s2
  where s2.table_id = t.id and s2.closed_at is null
  order by s2.opened_at desc
  limit 1
) s on true;

grant select on public.v_zone_table_status to authenticated;

-- 3) Recargar schema cache de PostgREST
notify pgrst, 'reload schema';
