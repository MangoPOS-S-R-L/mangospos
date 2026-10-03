-- Cierre de LA PENDA EXPRESS del 02/10/2026 23:07 (cajero 698825c7…) que salió
-- con Total Ventas 0 / Transacciones 0 y "esperado" = solo el fondo (7,000),
-- aunque se contaron 37,555 en efectivo y 75,644 en tarjeta.
--
-- El esperado sale de fn_get_cash_session_summary, que suma los payments con
-- session_id = ESTA caja. Esta consulta dice a qué caja fueron a parar los
-- cobros del negocio en ese turno (desde la apertura, o desde las 6 a. m. del
-- 02/10 si la caja se abrió más tarde, hasta el cierre). Solo lectura.
with s as (
  select crs.id, crs.user_id, crs.opened_at, crs.closed_at, crs.start_amount,
         crs.end_amount, crs.difference, cr.business_id, cr.name as caja
  from public.cash_register_sessions crs
  join public.cash_registers cr on cr.id = crs.cash_register_id
  where crs.user_id::text like '698825c7%'
    and crs.closed_at between timestamptz '2026-10-02 22:00-04'
                          and timestamptz '2026-10-03 00:30-04'
  order by abs(extract(epoch from crs.closed_at - timestamptz '2026-10-02 23:07-04'))
  limit 1
),
pay as (
  select p.session_id, p.processed_by,
         greatest(p.amount - coalesce(p.change_amount, 0), 0) as neto,
         case
           when pm.code = 'cash' or lower(coalesce(pm.name, '')) like '%efectivo%' then 'efectivo'
           when pm.code = 'card' or lower(coalesce(pm.name, '')) like '%tarjet%' then 'tarjeta'
           when pm.code = 'transfer' or lower(coalesce(pm.name, '')) like '%transfer%' then 'transferencia'
           when pm.code = 'credit' or lower(coalesce(pm.name, '')) in ('crédito', 'credito') then 'credito'
           else 'otro'
         end as metodo
  from s
  join public.payments p
    on p.business_id = s.business_id
   and p.status = 'completed'
   and p.created_at >= least(s.opened_at, timestamptz '2026-10-02 06:00-04')
   and p.created_at <= s.closed_at
  left join public.payment_methods pm on pm.id = p.payment_method_id
)
select
  case
    when count(pay.*) = 0       then '0. NINGUN cobro del negocio en ese horario'
    when pay.session_id = s.id  then '1. ESTA caja (la del cierre)'
    when pay.session_id is null then '3. SIN caja (session_id vacio)'
    when d.id is null           then '4. id que NO es una caja de cobro'
    else                             '2. OTRA caja'
  end                                                                        as destino,
  to_char(s.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
    || ' -> ' ||
  to_char(s.closed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as turno_del_cierre,
  su.email                                                                   as cajero_del_cierre,
  s.caja,
  pay.session_id                                                             as caja_destino,
  du.email                                                                   as dueno_caja_destino,
  d.status                                                                   as estado_caja_destino,
  to_char(d.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as abrio,
  to_char(d.closed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as cerro,
  count(pay.*)                                                               as cobros,
  coalesce(sum(pay.neto) filter (where pay.metodo = 'efectivo'), 0)          as efectivo,
  coalesce(sum(pay.neto) filter (where pay.metodo = 'tarjeta'), 0)           as tarjeta,
  coalesce(sum(pay.neto) filter (where pay.metodo = 'transferencia'), 0)     as transferencia,
  coalesce(sum(pay.neto) filter (where pay.metodo = 'credito'), 0)           as credito,
  coalesce(sum(pay.neto) filter (where pay.metodo = 'otro'), 0)              as otro,
  string_agg(distinct pu.email, ', ')                                        as quien_cobro
from s
left join pay on true
left join public.cash_register_sessions d on d.id = pay.session_id
left join auth.users su on su.id = s.user_id
left join auth.users du on du.id = d.user_id
left join auth.users pu on pu.id = pay.processed_by
group by s.id, s.opened_at, s.closed_at, s.caja, su.email,
         pay.session_id, d.id, du.email, d.status, d.opened_at, d.closed_at
order by destino, efectivo desc;
