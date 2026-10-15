-- =============================================================================
-- LA PENDA EXPRESS · TRANSFERENCIAS — qué pasar del Principal a cada área
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta. Correr DESPUÉS de PENDA_AREA_3 (las áreas
-- de los productos ya puestas) y ANTES de PENDA_ACT_3_encender.
--
-- Por qué: al encender, cada área descuenta de su almacén y el Almacén
-- Principal ya no vende. Lo que la caja vaya a vender tiene que estar en
-- FoodShop, Bar o Cocina; si está solo en el Principal, la caja lo marca
-- «Agotado» y el área queda en negativo.
--
-- Cómo decide el destino (lo mismo que hará el consumo con el inventario por
-- área encendido): producto de área COCINA → Cocina, de área BAR → Bar, lo
-- demás → FoodShop. El insumo sale del producto: el vinculado directo, o los
-- ingredientes de su receta.
--
-- SUGERIDO = lo que falta para cubrir 14 días de consumo (ventas de los
-- últimos 14 días × lo que descuenta cada venta), sin pasar de lo que hay en
-- el Principal. Es una guía: el que transfiere decide.
-- OJO: si un insumo lo gastan dos áreas (una cerveza que se vende en la
-- tienda y va en un cóctel del bar), sale una fila por área y las dos
-- sugerencias salen del mismo Principal.
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
alm as (
  select w.name, w.id from public.warehouses w, biz
   where w.business_id = biz.id and w.name in ('Almacen Principal','FoodShop','Bar','Cocina')
),
prod as (
  select m.id, m.inventory_item_id,
         exists (select 1 from public.recipes r where r.menu_item_id = m.id) as receta,
         coalesce(
           (select string_agg(upper(pa.name), '+' order by pa.name)
              from public.menu_item_print_areas x
              join public.print_areas pa on pa.id = x.print_area_id
             where x.menu_item_id = m.id),
           (select upper(pa.name) from public.print_areas pa
             where pa.business_id = m.business_id and pa.code = m.print_area_code
             limit 1),
           '') as areas
    from public.menu_items m, biz
   where m.business_id = biz.id and coalesce(m.is_active, true)
),
destino as (
  select p.*,
         case when p.areas ~ '\mCOCINA\M' then 'Cocina'
              when p.areas ~ '\mBAR\M'    then 'Bar'
              else 'FoodShop' end as almacen
    from prod p
),
ventas as (
  select oi.product_id, sum(coalesce(oi.qty, oi.quantity::numeric, 0)) as un
    from public.order_items oi
   where oi.created_at >= now() - interval '14 days'
     and oi.status <> 'void'
     and oi.product_id in (select id from prod)
   group by oi.product_id
),
consumo as (
  -- vínculo directo: una venta = una unidad del insumo
  select d.almacen, d.inventory_item_id as item_id, coalesce(v.un, 0) as q
    from destino d left join ventas v on v.product_id = d.id
   where d.inventory_item_id is not null and not d.receta
  union all
  -- receta: una venta = la cantidad de cada ingrediente
  select d.almacen, ri.inventory_item_id, coalesce(v.un, 0) * ri.quantity
    from destino d
    join public.recipes r on r.menu_item_id = d.id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    left join ventas v on v.product_id = d.id
   where ri.inventory_item_id is not null
),
necesidad as (
  select almacen, item_id, sum(q) as consumo_14d
    from consumo group by almacen, item_id
),
fila as (
  select n.almacen as destino, i.name as insumo, i.unit as unidad,
         coalesce(i.cost, 0) as costo,
         coalesce((select st.quantity from public.inventory_stock st
                    where st.item_id = n.item_id
                      and st.warehouse_id = (select id from alm where name = n.almacen)), 0) as en_destino,
         coalesce((select st.quantity from public.inventory_stock st
                    where st.item_id = n.item_id
                      and st.warehouse_id = (select id from alm where name = 'Almacen Principal')), 0) as en_principal,
         n.consumo_14d
    from necesidad n
    join public.inventory_items i on i.id = n.item_id
)
select destino,
       insumo,
       unidad,
       round(en_destino, 2)                                            as en_destino,
       round(en_principal, 2)                                          as en_principal,
       round(consumo_14d, 2)                                           as consumo_14d,
       round(least(en_principal, greatest(0, ceil(consumo_14d - en_destino))), 2) as sugerido,
       to_char(least(en_principal, greatest(0, ceil(consumo_14d - en_destino))) * costo,
               'FM999,999,990.00')                                     as valor
  from fila
 where least(en_principal, greatest(0, ceil(consumo_14d - en_destino))) > 0
 order by destino,
          least(en_principal, greatest(0, ceil(consumo_14d - en_destino))) * costo desc,
          insumo;
