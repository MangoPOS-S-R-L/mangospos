-- =============================================================================
-- DIAGNÓSTICO — Comandas que salieron a cocina y NO quedaron en ninguna cuenta
-- =============================================================================
-- Una fila por comanda (orden + envío a cocina). Solo lee. Es UNA sola
-- consulta: el SQL Editor muestra solo el último resultado.
-- Cambiar solo las líneas marcadas con <<<.
--
-- Qué cuenta como "desaparecida" (tiene que cumplir TODO):
--   * Salió a cocina: tiene marca de envío (o la hereda de su original si es
--     una fila creada al dividir la cuenta).
--   * Sigue sin cobrar: el producto no está 'paid'.
--   * No es algo que se quitó a propósito: ni producto anulado, ni orden
--     anulada ANTES de cargarle el producto, ni cortesía, ni producto a 0.
--   * Ninguna cuenta viva lo muestra. Tipos, del más grave al menos:
--       1 ORDEN HUÉRFANA: la orden sigue viva pero su mesa ya se cerró. No sale
--         en el salón ni en cuentas abiertas: nadie la va a cobrar.
--       2 CARGADO A UNA ORDEN YA CERRADA: el producto entró DESPUÉS de que la
--         orden se cerró o se anuló (p. ej. el barrendero anuló la orden
--         vacía y luego le cargaron el producto). El reporte de comandas hoy
--         lo pinta como "Orden anulada".
--       3 SUBCUENTA CERRADA: la mesa y la orden siguen abiertas, pero el
--         producto quedó en una subcuenta ya cerrada: no suma al total que se
--         cobra.
--       4 COBRADA SIN ÉL: la orden se cobró y este producto quedó fuera.
--
-- Columnas de ayuda:
--   quien_cerro_la_mesa  'app' si la mesa quedó cerrada ANTES de abrirse (la
--                        app escribe la hora local como UTC: el delator de las
--                        huérfanas por la carrera de liberar la mesa).
--   retecleado           cuántas de sus unidades se volvieron a digitar y
--                        cobrar en OTRA orden de la misma mesa (de 1 h antes a
--                        8 h después del envío). Si están todas, la plata SÍ
--                        entró: el daño es doble descuento de inventario.
--
-- Lo que NO puede salir aquí: un producto que se BORRÓ de la cuenta después
-- de enviarse. Borrar elimina la fila y no deja rastro en la base de datos.
-- =============================================================================

with params as (
  select
    -- El negocio de MUEBLE08 (orden 1506CFAD).
    (select o.business_id from public.orders o
      where o.id = '1506cfad-04bf-4d7d-8655-c89b4bf1e439') as bid,
    date '2026-09-01' as desde,   -- <<< primer día
    date '2026-09-19' as hasta    -- <<< último día (incluido)
),
rango as (
  select
    bid,
    (desde::timestamp at time zone 'America/Santo_Domingo')       as t0,
    ((hasta + 1)::timestamp at time zone 'America/Santo_Domingo') as t1
  from params
),
items as (
  select
    oi.id,
    oi.order_id,
    oi.product_id,
    oi.product_name,
    coalesce(nullif(oi.qty, 0), oi.quantity::numeric, 1)          as cant,
    oi.notes,
    oi.unit_price,
    oi.subtotal,
    oi.tax,
    oi.discounts,
    oi.total,
    oi.check_id,
    oi.created_at,
    coalesce(oi.kitchen_sent_at, sib.kitchen_sent_at)             as enviado_en,
    coalesce(oi.created_by_employee_id, sib.created_by_employee_id) as autor_id,
    -- status_ext manda: anular a veces deja status = 'open' con ext 'void'.
    case
      when o.status_ext::text = 'void' then 'canceled'
      when o.status_ext::text = 'paid' then 'paid'
      else o.status::text
    end                                                           as o_status,
    o.closed_at                                                   as o_cerrada,
    ts.table_id,
    ts.origin::text                                               as origen,
    ts.opened_at                                                  as mesa_abierta,
    ts.closed_at                                                  as mesa_cerrada,
    ts.opened_by_employee_id,
    exists (
      select 1 from public.order_item_modifiers m
      where m.item_id = oi.id and coalesce(m.price, 0) > 0
    )                                                             as mods_con_precio
  from public.order_items oi
  join public.orders o          on o.id = oi.order_id
  join public.table_sessions ts on ts.id = o.session_id
  cross join rango r
  -- Filas creadas al dividir la cuenta: sin marca, heredan la del original.
  left join lateral (
    select s.kitchen_sent_at, s.created_by_employee_id
    from public.order_items s
    where s.order_id = oi.order_id
      and s.kitchen_sent_at is not null
      and s.product_id is not distinct from oi.product_id
      and s.created_at = oi.created_at
    order by s.kitchen_sent_at
    limit 1
  ) sib on oi.kitchen_sent_at is null
  where o.business_id = r.bid
    and o.created_at <  r.t1
    and o.created_at >= r.t0 - interval '3 days'
    and oi.status::text not in ('draft', 'paid', 'void')
),
clasificados as (
  select
    i.*,
    case
      when i.o_cerrada is not null and i.created_at > i.o_cerrada
        then '2 Cargado a una orden ya cerrada o anulada'
      -- Anulada a propósito (el producto ya estaba cuando se anuló).
      when i.o_status = 'canceled' then null
      when i.o_cerrada is null and i.o_status <> 'paid'
           and i.mesa_cerrada is not null
        then '1 Orden huérfana: la mesa se cerró con la orden viva'
      when i.o_cerrada is null and i.o_status <> 'paid'
           and i.check_id is not null
           and not exists (
             select 1 from public.order_checks c
             where c.id = i.check_id and not c.is_closed
           )
        then '3 Quedó en una subcuenta cerrada'
      when i.o_cerrada is not null or i.o_status = 'paid'
        then '4 La orden se cobró sin este producto'
    end as tipo,
    -- ¿Se volvió a digitar y cobrar en otra orden de la misma mesa?
    (
      select upper(left(o2.id::text, 8))
      from public.order_items oi2
      join public.orders o2          on o2.id = oi2.order_id
      join public.table_sessions ts2 on ts2.id = o2.session_id
      where i.table_id is not null
        and ts2.table_id = i.table_id
        and o2.id <> i.order_id
        and oi2.product_id = i.product_id
        and oi2.status::text = 'paid'
        and oi2.created_at >= i.enviado_en - interval '1 hour'
        and oi2.created_at <  i.enviado_en + interval '8 hours'
      order by oi2.created_at
      limit 1
    ) as retecleado_en
  from items i
  cross join rango r
  where i.enviado_en >= r.t0
    and i.enviado_en <  r.t1
    -- Cortesía: nunca cuenta como desaparecida.
    and not (
      coalesce(i.notes, '') like '%[CORTESIA:%'
      or (
        coalesce(i.notes, '') not like '%[PROMO_AUTO:%'
        and coalesce(i.notes, '') not like '%[DEAL:%'
        and coalesce(i.unit_price, 0) > 0
        and (
          (
            coalesce(i.subtotal, 0) + coalesce(i.tax, 0) > 0
            and coalesce(i.discounts, 0)
                >= coalesce(i.subtotal, 0) + coalesce(i.tax, 0) - 0.01
          )
          or coalesce(i.total, 1) <= 0.01
        )
      )
    )
    -- Cobrado a 0: no había nada que cobrar.
    and not (
      (coalesce(i.unit_price, 0) <= 0 and not i.mods_con_precio)
      or (
        coalesce(i.unit_price, 0) * i.cant > 0
        and coalesce(i.discounts, 0) >= coalesce(i.unit_price, 0) * i.cant - 0.01
      )
    )
)
select
  c.tipo,
  to_char(c.enviado_en at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
                                                               as enviado,
  coalesce(
    dt.label, dt.code,
    case
      when c.origen = 'manual' then 'Venta manual'
      when c.origen in ('quick', 'quick_sale') then 'Venta rápida'
      else 'Venta'
    end
  )                                                            as mesa,
  upper(left(c.order_id::text, 8))                             as orden,
  coalesce(
    string_agg(distinct nullif(trim(concat_ws(' ', e.first_name, e.last_name)), ''), ' / '),
    max(nullif(trim(concat_ws(' ', oe.first_name, oe.last_name)), ''))
  )                                                            as mesero,
  -- Las filas partidas del mismo producto van juntas ("2 × Mofongo").
  (
    select string_agg(trim_scale(p.cant)::text || ' × ' || p.product_name, ', '
                      order by p.primero, p.product_name)
    from (
      select c2.product_name, sum(c2.cant) as cant, min(c2.created_at) as primero
      from clasificados c2
      where c2.tipo = c.tipo
        and c2.order_id = c.order_id
        and c2.enviado_en = c.enviado_en
      group by c2.product_name
    ) p
  )                                                            as productos,
  trim_scale(sum(c.cant))                                      as unidades,
  round(sum(coalesce(c.subtotal, 0) + coalesce(c.tax, 0)
            - coalesce(c.discounts, 0)), 2)                    as monto,
  min(c.o_status)                                              as estado_orden,
  to_char(min(c.o_cerrada) at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
                                                               as orden_cerrada,
  to_char(min(c.mesa_abierta) at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
                                                               as mesa_abierta,
  to_char(min(c.mesa_cerrada) at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
                                                               as mesa_cerrada,
  case
    when min(c.mesa_cerrada) is null then ''
    when min(c.mesa_cerrada) < min(c.mesa_abierta) then 'app (hora corrida)'
    else 'servidor o usuario'
  end                                                          as quien_cerro_la_mesa,
  trim_scale(coalesce(sum(c.cant) filter (where c.retecleado_en is not null), 0))
    || ' de ' || trim_scale(sum(c.cant)) || ' u.'              as retecleado,
  string_agg(distinct c.retecleado_en, ', ')                   as retecleado_en,
  c.order_id                                                   as order_id_completo
from clasificados c
left join public.dining_tables dt on dt.id = c.table_id
left join public.employees e      on e.id = c.autor_id
left join public.employees oe     on oe.id = c.opened_by_employee_id
where c.tipo is not null
group by c.tipo, c.order_id, c.enviado_en, dt.label, dt.code, c.origen
order by c.tipo, c.enviado_en;
