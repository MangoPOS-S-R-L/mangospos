-- =============================================================================
-- LA PENDA EXPRESS · RECETAS — PASO R1: cuánto gastó la cocina desde el conteo
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- NO TOCA EL INVENTARIO. Crea la función auxiliar `_penda_rec_consumo()` (el
-- cálculo que va a usar el PASO R2, así los dos dicen lo mismo) y muestra el
-- resumen.
--
-- QUÉ CALCULA (dueño, 12-oct: «activar las recetas y descontar con las ventas
-- para un estimado más real de lo que hay en cocina»):
--   lo que cada orden HABRÍA descontado si las recetas hubieran estado
--   encendidas desde el conteo del 1-oct, ORDEN POR ORDEN:
--     · platos de área COCINA con receta (y los componentes de combo con
--       receta), vendidos desde el congelado del conteo de Cocina;
--     · cantidad = receta × unidades vendidas, en la unidad base del insumo
--       (igual que consume_inventory_from_order);
--     · sin renglones anulados ni órdenes anuladas;
--     · sin los platos que YA descontaban (las 2 recetas que estaban
--       encendidas): esos ya se descontaron en su momento.
--   Todo sale del almacén Cocina.
--
-- POR QUÉ ORDEN POR ORDEN Y NO UN AJUSTE GLOBAL: el sistema concilia cada
-- orden contra lo que ESA orden ya descontó. Si el consumo hacia atrás se
-- asentara como un ajuste suelto, la primera vez que se tocara una de esas
-- órdenes (cobrar una mesa abierta, anular) volvería a descontar la receta:
-- doble descuento. Asentado como venta de la orden, la conciliación lo ve y
-- no repite; si la orden se anula, lo devuelve.
--
-- LO QUE NO ENTRA: las recetas del BAR (café, frappés, jugos). Esas empiezan
-- a descontar desde que se encienden; hacia atrás no.
--
-- QUÉ RECETAS SE ENCIENDEN (dueño, 12-oct) — tabla `_penda_rec_encender`:
--   · se enciende la receta que tiene AL MENOS UN ingrediente con existencia
--     (un insumo real: pechuga, queso, plátano). Sus «COCINA ·» que nunca se
--     compraron quedan en negativo y no importan;
--   · se APAGA la que no tiene ninguno con existencia (el plato se sigue
--     vendiendo, pero no descuenta);
--   · se APAGA también, hasta corregirla, la que tiene un RENGLÓN ABSURDO:
--     el renglón cuesta más que 5 veces el precio del plato (o más de
--     RD$5,000 si el plato no tiene precio). Así se cazaron PAPAS a 180
--     «unidades» por plato (RD$351,000 por hamburguesa) y dos insumos con el
--     costo de la libra o de la botella puesto por gramo o por ml.
--     Corregida la receta o el costo, se vuelve a correr este PASO R1 y entra.
-- =============================================================================

-- ═══ Qué recetas se encienden ═══════════════════════════════════════════════
do $$
declare
  v_biz uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
begin
  if to_regclass('public._penda_rec_movs') is not null then
    raise exception 'El PASO R2 ya se aplicó: no se rehace la lista. No se tocó nada.';
  end if;

  drop table if exists public._penda_rec_encender;
  create table public._penda_rec_encender as
  with
  ing as (
    select m.id as menu_item_id, m.name as producto, coalesce(m.price, 0) as precio,
           coalesce(m.is_inventory_tracked, false) as ya_encendida,
           i.name as insumo, i.unit, coalesce(i.cost, 0) as costo, ri.quantity,
           ri.quantity * coalesce(i.cost, 0) as costo_linea,
           coalesce((select sum(st.quantity)
                       from public.inventory_stock st
                       join public.warehouses w on w.id = st.warehouse_id
                      where st.item_id = i.id and w.business_id = v_biz), 0) > 0 as hay
      from public.menu_items m
      join public.recipes r on r.menu_item_id = m.id
      join public.recipe_ingredients ri on ri.recipe_id = r.id
      join public.inventory_items i on i.id = ri.inventory_item_id
     where m.business_id = v_biz
  ),
  raras as (
    select menu_item_id,
           string_agg(insumo || ' ' || regexp_replace(round(quantity, 2)::text, '\.?0+$', '')
                      || ' ' || coalesce(unit, '') || ' × RD$'
                      || regexp_replace(round(costo, 2)::text, '\.?0+$', '')
                      || ' = RD$' || to_char(costo_linea, 'FM999,999,990'),
                      ' · ' order by costo_linea desc) as detalle
      from ing
     where costo_linea > greatest(5 * precio, 5000)
     group by menu_item_id
  )
  select g.menu_item_id, g.producto, max(g.precio) as precio,
         bool_or(g.ya_encendida) as ya_encendida,
         count(*) as ingredientes,
         count(*) filter (where g.hay) as con_existencia,
         r.detalle as renglon_absurdo,
         not bool_or(g.ya_encendida)
           and count(*) filter (where g.hay) > 0
           and r.detalle is null as encender
    from ing g
    left join raras r on r.menu_item_id = g.menu_item_id
   group by g.menu_item_id, g.producto, r.detalle;
end
$$;

create or replace function public._penda_rec_consumo()
returns table (order_id uuid, item_id uuid, qty numeric)
language sql
stable
as $$
  with
  biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
  coc as (
    select w.id as wid, w.production_area_id as pa
      from public.warehouses w, biz
     where w.business_id = biz.id and w.name = 'Cocina'
  ),
  corte as (
    select min(desde) as desde from public._penda_act_plan where almacen = 'Cocina'
  ),
  -- área del producto: la N:M manda; si no tiene, el código (igual que la caja)
  areas as (
    select m.id, m.is_inventory_tracked, m.item_type,
           array(select x.print_area_id from public.menu_item_print_areas x
                  where x.menu_item_id = m.id) as nm,
           (select pa2.id from public.print_areas pa2
             where pa2.business_id = m.business_id and pa2.code = m.print_area_code
             limit 1) as legado
      from public.menu_items m, biz
     where m.business_id = biz.id
  ),
  es_cocina as (
    select a.id, a.is_inventory_tracked, a.item_type,
           coalesce((select c.pa from coc c) = any (
             case when cardinality(a.nm) > 0 then a.nm else array[a.legado] end), false) as cocina,
           cardinality(a.nm) = 0 and a.legado is null as sin_area
      from areas a
  ),
  ords as (
    select o.id
      from public.orders o
      join public.table_sessions ts on ts.id = o.session_id, biz
     where ts.business_id = biz.id
       and not (coalesce(o.status = 'canceled', false)
                or coalesce(o.status_ext = 'void'::public.order_status, false))
  ),
  filas as (
    -- (1) platos con receta
    select oi.order_id, ri.inventory_item_id as item_id,
           ri.quantity * coalesce(oi.qty, oi.quantity::numeric, 0) as q
      from public.order_items oi
      join ords on ords.id = oi.order_id
      join es_cocina p on p.id = oi.product_id
      join public._penda_rec_encender e on e.menu_item_id = oi.product_id and e.encender
      join public.recipes r on r.menu_item_id = oi.product_id
      join public.recipe_ingredients ri on ri.recipe_id = r.id
      cross join corte
     where oi.created_at >= corte.desde
       and oi.status <> 'void'
       and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
       and p.cocina
       and not coalesce(p.is_inventory_tracked, false)
       and coalesce(p.item_type, '') <> 'combo'
       and ri.inventory_item_id is not null
    union all
    -- (2) componentes de combo con receta: el área la manda el componente;
    --     si el componente no tiene área, la del combo
    select oi.order_id, ri.inventory_item_id,
           ri.quantity * coalesce(oim.qty, 1) * coalesce(oi.qty, oi.quantity::numeric, 0)
      from public.order_items oi
      join ords on ords.id = oi.order_id
      join es_cocina cb on cb.id = oi.product_id and cb.item_type = 'combo'
      join public.order_item_modifiers oim on oim.item_id = oi.id and oim.menu_item_id is not null
      join es_cocina cp on cp.id = oim.menu_item_id
      join public._penda_rec_encender e on e.menu_item_id = oim.menu_item_id and e.encender
      join public.recipes r on r.menu_item_id = oim.menu_item_id
      join public.recipe_ingredients ri on ri.recipe_id = r.id
      cross join corte
     where oi.created_at >= corte.desde
       and oi.status <> 'void'
       and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
       and not coalesce(cp.is_inventory_tracked, false)
       and (cp.cocina or (cp.sin_area and cb.cocina))
       and ri.inventory_item_id is not null
  ),
  -- lo que esas órdenes ya descontaron de Cocina (para no repetir)
  ya as (
    select im.reference_id as order_id, im.item_id, -sum(im.quantity) as q
      from public.inventory_movements im, coc
     where im.reference_type = 'order' and im.movement_type = 'sale'
       and im.warehouse_id = coc.wid
       and im.reference_id in (select f.order_id from filas f)
     group by im.reference_id, im.item_id
  )
  select f.order_id, f.item_id,
         greatest(sum(f.q), 0) - coalesce(max(y.q), 0)
    from filas f
    left join ya y on y.order_id = f.order_id and y.item_id = f.item_id
   group by f.order_id, f.item_id
  having greatest(sum(f.q), 0) - coalesce(max(y.q), 0) > 0
$$;


-- ═══ RESUMEN (una sola consulta) ════════════════════════════════════════════
--   R1  cuántas órdenes y renglones, y desde cuándo
--   R2  los 30 insumos que más gastó la cocina (al costo): cuánto había en
--       Cocina, cuánto queda, y cuánto se cubre del Principal
--   R3  lo que queda negativo sin de dónde cubrir (insumos «COCINA ·» que
--       nunca se compraron ni se contaron)
--   R0  cuántas recetas se encienden y cuántas se apagan, y por qué
--   R4  las recetas APAGADAS por un renglón absurdo: corregirlas y volver a
--       correr este paso
with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
c as (select * from public._penda_rec_consumo()),
w as (
  select w.name, w.id from public.warehouses w, biz
   where w.business_id = biz.id and w.name in ('Cocina','Almacen Principal','FoodShop')
),
por_item as (
  select c.item_id, sum(c.qty) as consumo, count(distinct c.order_id) as ordenes
    from c group by c.item_id
),
detalle as (
  select i.name as insumo, i.unit, coalesce(i.cost, 0) as costo, pi.consumo, pi.ordenes,
         coalesce((select st.quantity from public.inventory_stock st
                    where st.item_id = pi.item_id
                      and st.warehouse_id = (select id from w where name = 'Cocina')), 0) as cocina,
         coalesce((select st.quantity from public.inventory_stock st
                    where st.item_id = pi.item_id
                      and st.warehouse_id = (select id from w where name = 'Almacen Principal')), 0)
       + coalesce((select st.quantity from public.inventory_stock st
                    where st.item_id = pi.item_id
                      and st.warehouse_id = (select id from w where name = 'FoodShop')), 0) as fuera
    from por_item pi
    join public.inventory_items i on i.id = pi.item_id
),
calc as (
  select d.*,
         d.cocina - d.consumo                                        as cocina_despues,
         least(greatest(d.consumo - d.cocina, 0), greatest(d.fuera, 0)) as cubre
    from detalle d
)
select seccion, dato, valor from (
  select 0 as orden, 'R0 recetas' as seccion, x.motivo as dato,
         count(*) || ' · ' || left(string_agg(x.producto, ' · ' order by x.producto), 150) as valor,
         count(*)::numeric as peso
    from (select producto,
                 case when ya_encendida then 'ya estaban encendidas'
                      when encender then 'SE ENCIENDEN'
                      when renglon_absurdo is not null then 'APAGADA: renglón absurdo (ver R4)'
                      else 'APAGADA: ningún insumo con existencia' end as motivo
            from public._penda_rec_encender) x
   group by x.motivo
  union all
  select 1, 'R1 resumen', 'desde el conteo de Cocina' as dato,
         (select count(distinct order_id) from c) || ' órdenes · '
         || (select count(*) from c) || ' renglones (orden × insumo) · '
         || (select count(distinct item_id) from c) || ' insumos · desde '
         || (select to_char(min(desde) at time zone 'America/Santo_Domingo', 'DD-Mon HH24:MI')
               from public._penda_act_plan where almacen = 'Cocina') as valor,
         1e18::numeric as peso
  union all
  select * from (
    select 2, 'R2 lo que más gastó', insumo || ' (' || coalesce(unit, '') || ')',
           'gastó ' || regexp_replace(round(consumo, 2)::text, '\.?0+$', '')
           || ' en ' || ordenes || ' órdenes · Cocina ' || regexp_replace(round(cocina, 2)::text, '\.?0+$', '')
           || ' → ' || regexp_replace(round(cocina_despues + cubre, 2)::text, '\.?0+$', '')
           || case when cubre > 0 then ' (se pasan ' || regexp_replace(round(cubre, 2)::text, '\.?0+$', '')
                                       || ' del Principal/FoodShop)' else '' end
           || ' · ' || to_char(consumo * costo, 'FM999,999,990.00') || ' al costo',
           consumo * costo
      from calc
     order by consumo * costo desc
     limit 30
  ) top
  union all
  select 3, 'R3 queda negativo sin de dónde cubrir', 'insumos',
         count(*) || ' insumos (los «COCINA ·» que nunca se compraron ni se contaron, '
         || 'o el resto de lo que no alcanzó)',
         0
    from calc where cocina_despues + cubre < 0
  union all
  select 4, 'R4 corregir antes de encender', producto || ' (precio RD$'
         || to_char(precio, 'FM999,990') || ')', renglon_absurdo, 0
    from public._penda_rec_encender
   where renglon_absurdo is not null and not ya_encendida
) x
order by orden, peso desc;
