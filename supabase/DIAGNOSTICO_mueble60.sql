-- =============================================================================
-- MUEBLE60 · reconstrucción completa + quién borró · negocio 6d13ed3f
-- Los 4 Johnnie Walker 18 de las 00:43 del 20-sep.
-- Bloques: 1 la cuenta · 2 línea de tiempo · 3 quién borró · 4 auditoría
-- Una sola consulta (el SQL Editor solo muestra el último resultado).
-- =============================================================================
with ord as (
  select distinct r.order_id as id
  from public.order_item_removals r
  where r.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    and upper(coalesce(r.table_name, '')) = 'MUEBLE60'
    and r.removed_at >= timestamptz '2026-09-19 09:00:00-04:00'
    and r.order_id is not null
  union
  select o.id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  join public.dining_tables  dt on dt.id = ts.table_id
  where ts.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    and upper(coalesce(dt.label, dt.code)) = 'MUEBLE60'
    and ts.opened_at >= timestamptz '2026-09-19 09:00:00-04:00'
),
rem as (
  select r.*, round(r.quantity * coalesce(r.unit_price, 0), 2) as valor
  from public.order_item_removals r
  join ord on ord.id = r.order_id
),
pagos as (
  select p.order_id, sum(p.amount) as pagado, count(*) as n
  from public.payments p join ord on ord.id = p.order_id
  where p.status = 'completed'
  group by p.order_id
),
ncfs as (
  select f.order_id,
         string_agg(f.ncf_number || ' (' || f.status || ')', ', ') as ncf,
         min(f.issued_at) as primer_ncf
  from public.fiscal_documents f join ord on ord.id = f.order_id
  group by f.order_id
)

-- 1 · la cuenta
select
  '1 · CUENTA'                                                              as bloque,
  to_char(ts.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as hora,
  'abrió la mesa · cierra ' ||
    coalesce(to_char(ts.closed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
             'SIGUE ABIERTA')                                               as evento,
  'orden ' || left(o.id::text, 8) || ' · ' || o.status                      as producto,
  null::numeric                                                             as cant,
  o.total                                                                   as valor,
  coalesce(nullif(pw.full_name, ''), nullif(po.full_name, ''), '(?)')       as quien,
  'pagado: ' || coalesce(pg.pagado, 0)::text ||
    ' · NCF: ' || coalesce(nf.ncf, '—')                                     as detalle
from ord
join public.orders o          on o.id = ord.id
left join public.table_sessions ts on ts.id = o.session_id
left join public.profiles po  on po.id = ts.opened_by
left join public.profiles pw  on pw.id = ts.waiter_user_id
left join pagos pg            on pg.order_id = o.id
left join ncfs  nf            on nf.order_id = o.id

union all
-- 2 · lo que sigue vivo en la cuenta
select
  '2 · LINEA DE TIEMPO',
  to_char(coalesce(oi.kitchen_sent_at, oi.created_at) at time zone 'America/Santo_Domingo',
          'DD/MM HH24:MI'),
  case when oi.status::text = 'void' then '⚪ anulado (void)'
       when oi.status::text = 'draft' then '⚪ borrador (nunca fue a cocina)'
       else '🟢 sigue en la cuenta' end,
  oi.product_name,
  coalesce(nullif(oi.qty, 0), oi.quantity::numeric),
  round(coalesce(nullif(oi.qty, 0), oi.quantity::numeric) * coalesce(oi.unit_price, 0), 2),
  coalesce(nullif(trim(concat_ws(' ', ea.first_name, ea.last_name)), ''), '(sin autor)'),
  'subcuenta ' || coalesce(oc.label, '—') || ' · ' || oi.status::text
from public.order_items oi
join ord on ord.id = oi.order_id
left join public.employees    ea on ea.id = oi.created_by_employee_id
left join public.order_checks oc on oc.id = oi.check_id

union all
-- 2 · lo que se quitó
select
  '2 · LINEA DE TIEMPO',
  to_char(r.removed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
  case when r.change_type = 'deleted' then '🔴 BORRADO' else '🟠 REDUCIDO' end
    || case when r.is_user_action then '' else ' (interno)' end,
  r.product_name,
  r.quantity,
  r.valor,
  coalesce(nullif(trim(concat_ws(' ', eo.first_name, eo.last_name)), ''),
           nullif(p.full_name, ''), p.email, '(no identificado)'),
  'digitó: ' || coalesce(nullif(trim(concat_ws(' ', ea.first_name, ea.last_name)), ''), '(sin autor)')
    || ' · linea ' || coalesce(r.sent_source, '—')
    || ' · ' || coalesce(r.request_path, 'sin path')
    || ' · motivo: ' || coalesce(r.reason, 'NINGUNO')
from rem r
left join public.employees eo on eo.id = r.reason_employee_id
left join public.employees ea on ea.id = r.author_employee_id
left join public.profiles  p  on p.id  = r.removed_by

union all
-- 3 · quién borró (identidad completa de la cuenta que ejecutó el borrado)
select
  '3 · QUIEN BORRO',
  'resumen',
  count(*)::text || ' línea(s) quitadas',
  coalesce(nullif(p.full_name, ''), '(perfil sin nombre)'),
  sum(r.quantity),
  sum(r.valor),
  coalesce(p.email, '(sin email)'),
  'uid ' || coalesce(left(r.removed_by::text, 13), 'NULO')
    || ' · PIN anotado: '
    || coalesce(string_agg(distinct nullif(trim(concat_ws(' ', eo.first_name, eo.last_name)), ''), ', '),
                'la app no lo anota')
from rem r
left join public.profiles  p  on p.id  = r.removed_by
left join public.employees eo on eo.id = r.reason_employee_id
group by p.full_name, p.email, r.removed_by

order by 1, 2, 3;
