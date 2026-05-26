-- =====================================================================
-- ROLLBACK: revertir estado visual "precuenta impresa" en vista de mesas
-- =====================================================================
-- Vuelve la vista a su forma anterior (sin columna `status`) y elimina
-- la columna `precheck_printed_at`. Seguro de correr en cualquier orden;
-- las mesas siempre saldrán en naranja/verde tras este rollback.
-- =====================================================================

-- 1) Recrear vista sin columna `status`.
-- IMPORTANTE: Postgres no deja quitar columnas con `create or replace
-- view` — hay que dropear primero y recrear. Si otras vistas o
-- procedures dependen de esta, el DROP fallará con "cannot drop view
-- because other objects depend on it"; en ese caso usar
-- `DROP VIEW ... CASCADE` (revisa antes con `\d+ v_zone_table_status`).
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
  coalesce((select count(*) from public.orders o where o.session_id = s.id),0) as orders_count
from public.dining_tables t
join public.zones z on z.id = t.zone_id
left join lateral (
  select * from public.table_sessions s2
  where s2.table_id = t.id and s2.closed_at is null
  order by s2.opened_at desc
  limit 1
) s on true;

grant select on public.v_zone_table_status to authenticated;

-- 2) Drop column
alter table public.table_sessions
  drop column if exists precheck_printed_at;

-- 3) Reload schema
notify pgrst, 'reload schema';
