-- =============================================================================
-- R3 · ¿Se borró por ERROR o A PROPÓSITO? · negocio 6d13ed3f
-- =============================================================================
-- Solo lee. UNA sola consulta (el SQL Editor muestra solo el último
-- resultado). Cambiar solo las líneas marcadas con <<<.
--
-- EL MOTIVO NO ESTÁ: la app pide un motivo al borrar y hoy lo descarta (falta
-- desplegar `noteItemRemoval`). Así que la intención se deduce de tres cosas
-- que sí quedaron registradas:
--
--   1. EL RELOJ. Borrar 40 segundos después de digitar es corregir. Borrar
--      horas después, con la comanda ya impresa y el trago servido, no.
--   2. ¿VOLVIÓ A LA CUENTA? Si el mismo producto se volvió a digitar en esa
--      mesa (o quedó otra línea igual en la orden), fue una corrección: la
--      botella igual se cobró. Si no volvió, salió de la cuenta y no regresó.
--   3. ¿QUÉ PASÓ CON LA CUENTA? Borrar minutos antes de cobrar, y que la
--      orden se cobre sin ese producto, es el patrón de una fuga.
--
-- COLUMNAS:
--   seg_desde_alta      segundos entre digitar el producto y borrarlo.
--   min_desde_envio     minutos entre que salió la comanda y el borrado.
--   min_antes_del_cobro minutos entre el borrado y el cobro de la orden.
--                       Un número chico = se borró justo antes de cobrar.
--   volvio_a_la_mesa    unidades del mismo producto digitadas DESPUÉS en esa
--                       mesa (misma sesión u otra sesión dentro de 3 h).
--   quedan_iguales      unidades vivas del mismo producto en la MISMA orden
--                       (si hay, se borró un duplicado).
--   cobrado_en_la_mesa  unidades del mismo producto que sí se cobraron en esa
--                       mesa después del borrado.
--
-- LO QUE ESTO NO PUEDE DECIR: la intención de una persona. Dice si el papel
-- y el reloj cuadran con una corrección o no. La prueba definitiva de si la
-- mercancía salió es el CONTEO FÍSICO de esos productos.
-- =============================================================================

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,          -- <<< negocio
    timestamptz '2026-09-19 09:00:00-04:00'      as desde         -- <<< desde
),
quitado as (
  select
    r.*,
    coalesce(r.session_id, o.session_id)                as sesion,
    o.closed_at                                         as orden_cerrada,
    case
      when o.status_ext::text = 'void' then 'canceled'
      when o.status_ext::text = 'paid' then 'paid'
      else o.status::text
    end                                                 as estado_orden,
    round(r.quantity * coalesce(r.unit_price, 0), 2)    as valor,
    coalesce(
      nullif(pf.full_name, ''), pf.email,
      left(r.removed_by::text, 8), '(no identificado)'
    )                                                   as cuenta_tablet
  from public.order_item_removals r
  cross join params p
  left join public.orders o   on o.id = r.order_id
  left join public.profiles pf on pf.id = r.removed_by
  where r.business_id = p.bid
    and r.removed_at >= p.desde
    -- Fuera la reescritura interna de dividir la cuenta: nadie borró nada.
    and r.is_user_action
),
mesa as (
  -- La mesa física de cada borrado, para seguir el producto aunque la
  -- cuenta se haya cerrado y abierto otra.
  select q.id, ts.table_id
  from quitado q
  left join public.table_sessions ts on ts.id = q.sesion
),
volvio as (
  -- ¿El mismo producto volvió a digitarse en esa mesa después del borrado?
  select
    q.id,
    coalesce(sum(coalesce(nullif(oi.qty, 0), oi.quantity::numeric)), 0) as unidades,
    coalesce(sum(coalesce(nullif(oi.qty, 0), oi.quantity::numeric))
             filter (where oi.status::text = 'paid'), 0)                as cobradas
  from quitado q
  join mesa m on m.id = q.id
  left join public.table_sessions ts2 on ts2.table_id = m.table_id
  left join public.orders o2          on o2.session_id = ts2.id
  left join public.order_items oi     on oi.order_id = o2.id
        and oi.product_id is not distinct from q.product_id
        and oi.status::text not in ('draft', 'void')
        -- Digitado después del borrado (2 min de tolerancia de reloj) y
        -- dentro de las 3 horas siguientes: más allá ya es otra visita.
        and oi.created_at >= q.removed_at - interval '2 minutes'
        and oi.created_at <  q.removed_at + interval '3 hours'
  group by q.id
),
duplicados as (
  -- Unidades vivas del mismo producto en la MISMA orden: si quedan, lo que
  -- se borró era una línea repetida.
  select
    q.id,
    coalesce(sum(coalesce(nullif(oi.qty, 0), oi.quantity::numeric)), 0) as unidades
  from quitado q
  left join public.order_items oi
         on oi.order_id = q.order_id
        and oi.product_id is not distinct from q.product_id
        and oi.status::text not in ('draft', 'void')
  group by q.id
)
select
  to_char(q.removed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
                                                               as cuando,
  q.table_name                                                 as mesa,
  upper(left(q.order_id::text, 8))                             as orden,
  q.product_name                                               as producto,
  trim_scale(q.quantity)                                       as cant,
  q.valor,
  round(extract(epoch from (q.removed_at - q.item_created_at))::numeric, 0)
                                                               as seg_desde_alta,
  round(extract(epoch from (q.removed_at - q.kitchen_sent_at))::numeric / 60, 1)
                                                               as min_desde_envio,
  round(extract(epoch from (q.orden_cerrada - q.removed_at))::numeric / 60, 1)
                                                               as min_antes_del_cobro,
  trim_scale(v.unidades)                                       as volvio_a_la_mesa,
  trim_scale(d.unidades)                                       as quedan_iguales,
  trim_scale(v.cobradas)                                       as cobrado_en_la_mesa,
  coalesce(q.estado_orden, '(orden borrada)')                  as estado_orden,
  case
    when q.estado_orden = 'canceled'
      then '⚪ orden anulada'
    when d.unidades > 0
      then '🟢 CORRECCIÓN: quedó otra línea igual en la orden'
    when v.unidades > 0
      then '🟢 CORRECCIÓN: el producto volvió a la mesa'
    when q.kitchen_sent_at is null
         and q.removed_at - q.item_created_at < interval '2 minutes'
      then '🟢 error de digitación: nunca salió a cocina'
    when q.removed_at - q.item_created_at < interval '2 minutes'
      then '🟡 borrado en menos de 2 min, pero la comanda YA salió'
    when q.estado_orden = 'paid'
      then '🔴 se cobró la cuenta SIN el producto y no volvió'
    when q.orden_cerrada is null
      then '🟡 la cuenta sigue abierta'
    else '🟡 revisar'
  end                                                          as veredicto,
  q.cuenta_tablet,
  coalesce(q.reason, '(sin motivo: falta desplegar el registro del motivo)')
                                                               as motivo
from quitado q
join volvio v     on v.id = q.id
join duplicados d on d.id = q.id
-- Agrupadas por veredicto (🔴 primero) y dentro de cada grupo, en orden de
-- reloj: así se lee de un vistazo cuántas son de cada tipo.
order by
  case
    when q.estado_orden = 'canceled' then 4
    when d.unidades > 0 or v.unidades > 0 then 3
    when q.removed_at - q.item_created_at < interval '2 minutes' then 2
    when q.estado_orden = 'paid' then 0
    else 1
  end,
  q.removed_at;
