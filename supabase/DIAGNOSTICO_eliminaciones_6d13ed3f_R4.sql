-- =============================================================================
-- R4 · ¿El producto borrado se digitó en OTRA mesa? · negocio 6d13ed3f
-- =============================================================================
-- Solo lee. UNA sola consulta. Cambiar solo las líneas marcadas con <<<.
--
-- POR QUÉ: la R3 busca si el producto volvió a la MISMA mesa. Pero borrar de
-- una mesa y digitar en otra es lo que hace un mesero que se equivocó de
-- mesa: la botella igual salió y igual se cobró, solo que en otra cuenta.
-- Esta consulta toma cada borrado que la R3 dejó en rojo y busca el mismo
-- producto digitado en CUALQUIER mesa dentro de una ventana de tiempo.
--
-- COLUMNAS:
--   candidatas     cuántas líneas del mismo producto se digitaron en otras
--                  mesas dentro de la ventana.
--   donde          mesa · orden · hora · estado de cada candidata.
--   veredicto      🔴 si NO hay ninguna · 🟡 si las hay.
--
-- CÓMO LEERLO (corrido en prod 2026-09-20, aprendido a golpes):
--   * El dato fuerte es el CERO. Si en 45 minutos nadie digitó ese producto
--     en ninguna mesa, el cambio de mesa queda descartado.
--   * Muchas candidatas NO prueban nada en un producto de alta rotación:
--     24 Aguas de Coco en 45 minutos es la venta normal de la noche, no un
--     cambio de mesa. Sirve solo en productos que se venden poco.
--
-- La ventana por defecto es de 45 minutos hacia atrás y hacia adelante: un
-- cambio de mesa se hace en el momento, no dos horas después.
-- =============================================================================

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,        -- <<< negocio
    timestamptz '2026-09-19 09:00:00-04:00'      as desde,      -- <<< desde
    interval '45 minutes'                        as ventana     -- <<< ventana
),
quitado as (
  select
    r.*,
    round(r.quantity * coalesce(r.unit_price, 0), 2) as valor,
    case
      when o.status_ext::text = 'void' then 'canceled'
      when o.status_ext::text = 'paid' then 'paid'
      else o.status::text
    end                                              as estado_orden
  from public.order_item_removals r
  cross join params p
  left join public.orders o on o.id = r.order_id
  where r.business_id = p.bid
    and r.removed_at >= p.desde
    and r.is_user_action
),
-- Solo los que la R3 dejó sin explicación: no quedó otra línea igual en la
-- orden ni volvió el producto a esa misma mesa.
sin_explicar as (
  select q.*
  from quitado q
  where not exists (
    select 1
    from public.order_items oi
    where oi.order_id = q.order_id
      and oi.product_id is not distinct from q.product_id
      and oi.status::text not in ('draft', 'void')
  )
),
otras as (
  select
    s.id,
    count(*)                                                  as candidatas,
    string_agg(
      coalesce(dt.label, dt.code, 'Venta') || ' · #' ||
      upper(left(o2.id::text, 8)) || ' · ' ||
      to_char(oi.created_at at time zone 'America/Santo_Domingo', 'HH24:MI') ||
      ' · ' || oi.status::text,
      ' | ' order by oi.created_at
    )                                                         as donde
  from sin_explicar s
  cross join params p
  join public.order_items oi
    on oi.product_id is not distinct from s.product_id
   and oi.status::text not in ('draft', 'void')
   and oi.created_at >= s.removed_at - p.ventana
   and oi.created_at <= s.removed_at + p.ventana
  join public.orders o2          on o2.id = oi.order_id
                                and o2.business_id = p.bid
                                -- Otra cuenta, no la misma de la que se borró.
                                and o2.id <> s.order_id
  join public.table_sessions ts2 on ts2.id = o2.session_id
  left join public.dining_tables dt on dt.id = ts2.table_id
  group by s.id
)
select
  to_char(s.removed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
                                                    as cuando,
  s.table_name                                      as mesa_del_borrado,
  upper(left(s.order_id::text, 8))                  as orden,
  s.product_name                                    as producto,
  trim_scale(s.quantity)                            as cant,
  s.valor,
  coalesce(o.candidatas, 0)                         as candidatas,
  coalesce(o.donde, '—')                            as donde,
  s.estado_orden,
  case
    when coalesce(o.candidatas, 0) > 0
      then '🟡 hay otras líneas del mismo producto cerca (no concluye)'
    else '🔴 nadie digitó ese producto en otra mesa: no fue cambio de mesa'
  end                                               as veredicto
from sin_explicar s
left join otras o on o.id = s.id
order by (o.candidatas is not null), s.valor desc, s.removed_at;
