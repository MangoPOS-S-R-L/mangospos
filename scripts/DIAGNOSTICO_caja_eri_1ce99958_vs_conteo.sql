-- La caja de eri@penda.com (1ce99958…, abierta 02/10 15:10) sigue ABIERTA y
-- tiene las ventas de la tarde/noche. El conteo de las 23:07 (37,555 efectivo
-- / 75,644 tarjeta) se firmó en otra caja, vacía, abierta a las 23:01 por
-- pruebacaja@penda.com. Esta consulta compara la caja de Eri HASTA las 23:07
-- contra ese conteo, y dice si le siguieron entrando cobros después.
-- Misma fórmula que fn_get_cash_session_summary, con corte de hora. Solo lectura.
with x as (
  select '1ce99958-b507-46ad-8518-801a5b46ede4'::uuid as id,
         timestamptz '2026-10-02 23:07-04'           as corte
),
s as (
  select crs.*, cr.name as caja
  from x
  join public.cash_register_sessions crs on crs.id = x.id
  join public.cash_registers cr on cr.id = crs.cash_register_id
),
ct as (
  select
    coalesce(sum(c.amount) filter (
      where c.type = 'sale'
        and not exists (select 1 from public.payments p
                        where p.order_id = c.related_order_id
                          and p.status in ('cancelled', 'void'))), 0) as ventas_efectivo,
    coalesce(sum(c.amount) filter (where c.type = 'deposit'), 0)     as depositos,
    coalesce(sum(c.amount) filter (where c.type = 'withdrawal'), 0)  as retiros,
    coalesce(sum(c.amount) filter (where c.type = 'expense'), 0)     as gastos
  from x
  join public.cash_transactions c on c.session_id = x.id and c.created_at <= x.corte
),
pg as (
  select
    coalesce(sum(greatest(p.amount - coalesce(p.change_amount, 0), 0)) filter (
      where pm.code = 'card' or lower(coalesce(pm.name, '')) like '%tarjet%'), 0)     as tarjeta,
    coalesce(sum(greatest(p.amount - coalesce(p.change_amount, 0), 0)) filter (
      where pm.code = 'transfer' or lower(coalesce(pm.name, '')) like '%transfer%'), 0) as transferencia
  from x
  join public.payments p on p.session_id = x.id and p.status = 'completed'
                        and p.created_at <= x.corte
  left join public.payment_methods pm on pm.id = p.payment_method_id
),
despues as (
  select count(*)                                                       as cobros,
         coalesce(sum(greatest(p.amount - coalesce(p.change_amount, 0), 0)), 0) as monto,
         max(p.created_at)                                              as ultimo
  from x
  join public.payments p on p.session_id = x.id and p.status = 'completed'
                        and p.created_at > x.corte
)
select
  s.status                                                                  as estado,
  u.email                                                                   as dueno,
  s.caja,
  s.device_name                                                             as equipo,
  to_char(s.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as abrio,
  s.start_amount                                                            as fondo,
  ct.ventas_efectivo, ct.depositos, ct.retiros, ct.gastos,
  s.start_amount + ct.ventas_efectivo + ct.depositos - ct.retiros - ct.gastos as esperado_efectivo_2307,
  37555                                                                     as contado_efectivo,
  37555 - (s.start_amount + ct.ventas_efectivo + ct.depositos
           - ct.retiros - ct.gastos)                                        as dif_efectivo,
  pg.tarjeta                                                                as esperado_tarjeta_2307,
  75644                                                                     as contado_tarjeta,
  75644 - pg.tarjeta                                                        as dif_tarjeta,
  pg.transferencia                                                          as esperado_transf_2307,
  despues.cobros                                                            as cobros_despues_2307,
  despues.monto                                                             as monto_despues_2307,
  to_char(despues.ultimo at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as ultimo_cobro
from s
cross join ct
cross join pg
cross join despues
left join auth.users u on u.id = s.user_id;
