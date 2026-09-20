-- =============================================================================
-- Inventario vs cobrado · negocio 6d13ed3f · órdenes desde 19-sep 9:00 AM (RD)
--
-- Compara, por producto con link directo a inventario
-- (menu_items.inventory_item_id), lo que se COBRÓ contra lo que el inventario
-- DESCONTÓ. El consumo lo escribe consume_inventory_from_order como
-- movement_type='sale', reference_type='order', quantity NEGATIVA (la
-- devolución es positiva) — por eso descontado = -sum(quantity).
--
-- El consumo ocurre al enviar a cocina, no al pagar: lo de órdenes todavía
-- abiertas va en su propia columna para que no ensucie la diferencia.
-- Una sola consulta (el SQL Editor solo muestra el último resultado).
-- =============================================================================
with ordenes as (
  select o.id, o.status
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  where ts.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    and o.created_at >= timestamptz '2026-09-19 09:00:00-04:00'
),
cobrado as (
  select
    mi.inventory_item_id                                                    as item_id,
    mi.name                                                                 as producto,
    sum(coalesce(nullif(oi.qty, 0), oi.quantity::numeric))                  as unidades,
    sum(round(coalesce(nullif(oi.qty, 0), oi.quantity::numeric)
              * coalesce(oi.unit_price, 0), 2))                             as valor
  from public.order_items oi
  join ordenes o           on o.id = oi.order_id and o.status = 'paid'
  join public.menu_items mi on mi.id = oi.product_id
  where mi.inventory_item_id is not null
    and oi.status::text not in ('draft', 'void')
  group by 1, 2
),
movido as (
  select
    im.item_id,
    -sum(im.quantity) filter (where o.status = 'paid')                      as desc_pagadas,
    -sum(im.quantity) filter (where o.status <> 'paid')                     as desc_abiertas
  from public.inventory_movements im
  join ordenes o on o.id = im.reference_id
  where im.reference_type = 'order'
    and im.movement_type  = 'sale'
    -- Solo productos terminados con link directo. Sin esto entrarían los
    -- insumos descontados por RECETA, que no se comparan 1:1 con unidades
    -- cobradas y saldrían como falsos descuadres.
    and im.item_id in (
      select mi.inventory_item_id from public.menu_items mi
      where mi.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
        and mi.inventory_item_id is not null
    )
  group by 1
),
quitado as (
  select mi.inventory_item_id as item_id, sum(r.quantity) as unidades
  from public.order_item_removals r
  join public.menu_items mi on mi.id = r.product_id
  where r.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    and r.removed_at >= timestamptz '2026-09-19 09:00:00-04:00'
    and r.is_user_action
    and mi.inventory_item_id is not null
  group by 1
),
base as (
  select
    coalesce(c.item_id, m.item_id, q.item_id)          as item_id,
    coalesce(c.producto, ii.name, '(sin producto)')    as producto,
    coalesce(c.unidades, 0)                            as cobrado,
    coalesce(m.desc_pagadas, 0)                        as descontado,
    coalesce(m.desc_abiertas, 0)                       as en_abiertas,
    coalesce(q.unidades, 0)                            as quitado,
    coalesce(c.valor, 0)                               as valor_cobrado
  from cobrado c
  full join movido  m on m.item_id = c.item_id
  full join quitado q on q.item_id = coalesce(c.item_id, m.item_id)
  left join public.inventory_items ii on ii.id = coalesce(c.item_id, m.item_id, q.item_id)
)

select
  '1 · TOTAL'                              as bloque,
  'todos los productos con inventario'     as producto,
  sum(cobrado)                             as cobrado,
  sum(descontado)                          as descontado,
  sum(descontado) - sum(cobrado)           as diferencia,
  sum(en_abiertas)                         as en_ordenes_abiertas,
  sum(quitado)                             as quitado_de_cuentas,
  sum(valor_cobrado)                       as valor_cobrado,
  ''                                       as veredicto
from base

union all
select
  '2 · POR PRODUCTO',
  producto,
  cobrado,
  descontado,
  descontado - cobrado,
  en_abiertas,
  quitado,
  valor_cobrado,
  case
    when abs(descontado - cobrado) < 0.001 then '✅ cuadra'
    when descontado < cobrado              then '🔴 se cobró MÁS de lo que descontó el inventario'
    else                                        '🟡 el inventario descontó MÁS de lo cobrado'
  end
from base
where cobrado <> 0 or descontado <> 0 or quitado <> 0

-- (en un UNION, ORDER BY solo acepta columnas de salida o posiciones)
order by 1, 5, 8 desc;
