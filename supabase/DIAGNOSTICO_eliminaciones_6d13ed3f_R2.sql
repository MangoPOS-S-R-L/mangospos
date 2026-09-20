-- =============================================================================
-- R2 · ¿Qué pasó con la cuenta después del borrado? · negocio 6d13ed3f
-- Rango: 19-sep 9:00 AM (RD) → ahora. Solo lo quitado por el USUARIO
--        (borrados y reducciones); excluye la reescritura interna.
-- Responde: ¿se borró un duplicado o la única línea? ¿la orden se cobró?
--           ¿el borrado fue después de emitir el NCF? (hallazgo H-3)
-- Una sola consulta (el SQL Editor solo muestra el último resultado).
-- =============================================================================
with r as (
  select
    r.*,
    round(r.quantity * coalesce(r.unit_price, 0), 2) as valor,
    coalesce(nullif(p.full_name, ''), p.email, left(r.removed_by::text, 8), '(no identificado)') as cuenta
  from public.order_item_removals r
  left join public.profiles p on p.id = r.removed_by
  where r.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    and r.removed_at >= timestamptz '2026-09-19 09:00:00-04:00'
    and r.is_user_action
),
quedan as (
  select
    r.id,
    coalesce(sum(coalesce(nullif(oi.qty, 0), oi.quantity::numeric)), 0) as unidades_vivas
  from r
  left join public.order_items oi
         on oi.order_id = r.order_id
        and oi.product_id is not distinct from r.product_id
        and oi.status::text not in ('draft', 'void')
  group by r.id
),
fact as (
  select
    r.id,
    string_agg(distinct f.ncf_number, ', ')                                as ncf,
    bool_or(f.status = 'active' and f.issued_at < r.removed_at)            as borrado_tras_ncf
  from r
  join public.fiscal_documents f on f.order_id = r.order_id
  group by r.id
),
pagos as (
  select r.id, sum(p.amount) as pagado
  from r
  join public.payments p on p.order_id = r.order_id and p.status = 'completed'
  group by r.id
)
select
  to_char(r.removed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as cuando,
  r.table_name                                                               as mesa,
  r.product_name                                                             as producto,
  r.valor,
  r.cuenta                                                                   as cuenta_tablet,
  q.unidades_vivas                                                           as quedan_iguales,
  coalesce(o.status, '(orden borrada)')                                      as estado_orden,
  o.total                                                                    as total_orden,
  coalesce(pg.pagado, 0)                                                     as pagado,
  coalesce(f.ncf, '—')                                                       as ncf,
  case
    when f.borrado_tras_ncf         then '🔴 BORRADO DESPUÉS DEL NCF'
    when o.status = 'canceled'      then '⚪ orden anulada'
    when q.unidades_vivas > 0       then '🟡 quedó otra línea igual (¿duplicado?)'
    when o.status = 'paid'          then '🔴 se cobró la orden SIN este producto'
    when o.id is null               then '⚪ la orden ya no existe'
    else                                 '🟢 orden todavía abierta'
  end                                                                        as veredicto,
  coalesce(r.sent_source, '—')                                               as origen_linea,
  coalesce(r.request_path, '(sin path)')                                     as camino
from r
left join quedan q  on q.id = r.id
left join fact   f  on f.id = r.id
left join pagos  pg on pg.id = r.id
left join public.orders o on o.id = r.order_id
order by r.removed_at;
