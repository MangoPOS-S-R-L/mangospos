-- =============================================================================
-- ¿Las 120 aguas que salieron por conteo son ventas que el sistema NO descontó?
--
-- Negocio 6d13ed3f, ventana 2026-09-19 09:00 (hora RD) -> ahora.
--
-- CÓMO DESCUENTA EL SISTEMA: `consume_inventory_from_order` corre cuando la
-- orden pasa a 'sent_to_kitchen' (trigger trigger_inventory_on_order_sent),
-- NO cuando se cobra. Las 61 cuentas abiertas de esta noche ya están en
-- 'sent_to_kitchen', así que su stock YA debería estar descontado aunque la
-- mesa siga sin pagar. Si no se descontó, el producto no está vinculado.
--
-- TRES RUTAS posibles para que una venta descuente stock:
--   a) menu_items.inventory_item_id  -> link directo (terminados: agua, cerveza)
--   b) receta (recipes + recipe_ingredients)
--   c) ninguna -> la venta NUNCA toca el inventario
-- Y ADEMÁS `menu_items.is_inventory_tracked` tiene que estar en true. Esa
-- columna nació en false y SIN backfill (mig 20260514_0011), así que los
-- productos viejos no participan hasta que alguien los marque a mano.
--
-- LECTURA: si `unidades_vendidas` es ~120 y `descontado_por_venta` es 0,
-- el conteo está tapando un hueco que se va a repetir TODAS las noches.
-- =============================================================================

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,
    (timestamp '2026-09-19 09:00' at time zone 'America/Santo_Domingo') as desde,
    now() as hasta
),
ventas as (
  select
    oi.product_id,
    coalesce(nullif(btrim(oi.product_name), ''), 'Sin nombre') as producto,
    sum(coalesce(oi.qty, oi.quantity::numeric, 0)) as unidades_vendidas,
    count(*) as lineas
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  join public.table_sessions ts on ts.id = o.session_id
  cross join params p
  where ts.business_id = p.bid
    and oi.status <> 'void'
    and o.status_ext is distinct from 'void'
    and oi.created_at >= p.desde
    and oi.created_at <  p.hasta
    and oi.product_name ilike '%agua%'
  group by 1, 2
)
select
  v.producto,
  v.unidades_vendidas,
  v.lineas,
  mi.is_inventory_tracked                             as marcado_inventariable,
  case
    when mi.id is null                        then 'producto borrado del menú'
    when mi.inventory_item_id is not null      then 'link directo'
    when exists (
      select 1 from public.recipes r
      join public.recipe_ingredients ri on ri.recipe_id = r.id
      where r.menu_item_id = mi.id
    )                                          then 'receta'
    else                                            'SIN VÍNCULO'
  end                                                 as ruta_inventario,
  ii.name                                             as item_inventario,
  coalesce(mv.salidas_por_venta, 0)                   as descontado_por_venta,
  coalesce(mv.ajustes, 0)                             as ajustes_en_la_ventana,
  coalesce(st.stock, 0)                               as stock_actual
from ventas v
cross join params p
left join public.menu_items mi on mi.id = v.product_id
left join public.inventory_items ii on ii.id = mi.inventory_item_id
left join lateral (
  select
    sum(abs(m.quantity)) filter (where m.movement_type = 'sale')       as salidas_por_venta,
    sum(m.quantity)      filter (where m.movement_type = 'adjustment') as ajustes
  from public.inventory_movements m
  where m.item_id = mi.inventory_item_id
    and m.created_at >= p.desde
    and m.created_at <  p.hasta
) mv on true
left join lateral (
  select sum(s.quantity) as stock
  from public.inventory_stock s
  where s.item_id = mi.inventory_item_id
) st on true
order by v.unidades_vendidas desc;
