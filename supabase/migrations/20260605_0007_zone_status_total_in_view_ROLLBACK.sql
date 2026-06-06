-- =============================================================================
-- ROLLBACK de 20260605_0007 — restaura v_zone_table_status SIN total/customer/
-- waiter_name/is_own (versión de 20260525_0001).
--
-- OJO: zones_repository.dart fue simplificado para CONFIAR en que la vista trae
-- total/waiter_name/is_own/customer_name. Si reviertes la vista, DEBES revertir
-- también ese repo (git) o las cards mostrarán total/mozo en blanco.
-- =============================================================================

begin;

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

notify pgrst, 'reload schema';

commit;
