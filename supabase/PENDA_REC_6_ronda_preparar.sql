-- =============================================================================
-- LA PENDA EXPRESS · RECETAS — RONDA DE ENCENDIDO, paso 1: PREPARAR
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- NO TOCA EL INVENTARIO. Reutilizable: se corre cada vez que se corrigen
-- recetas o existencias (los huevos, el aceite, la carne molida, las papas…)
-- y algunas recetas APAGADAS pasan a calificar. Luego se aplica con
-- PENDA_REC_7_ronda_aplicar.sql. Es el mismo criterio del R1/R2 del 12-oct:
--
--   · entra toda receta APAGADA (is_inventory_tracked = false) que tenga al
--     menos UN ingrediente con existencia y NINGÚN renglón absurdo (cuesta más
--     de 5 veces el precio del plato, o más de RD$5,000);
--   · lo que esas recetas gastaron desde el conteo del 1-oct se asienta ORDEN
--     POR ORDEN en Cocina (platos de área COCINA), sin repetir lo que la orden
--     ya descontó (`_penda_rec_ronda_consumo`, la misma cuenta del R1).
--
-- Cada ronda tiene su número. Si la última no se aplicó, se rehace sobre el
-- mismo número.
-- =============================================================================

do $$
declare
  v_biz   uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_ronda int;
begin
  create table if not exists public._penda_rec_ronda (
    ronda       int primary key,
    creado_en   timestamptz not null default now(),
    aplicado_en timestamptz
  );
  create table if not exists public._penda_rec_ronda_lista (
    ronda           int not null,
    menu_item_id    uuid not null,
    producto        text,
    precio          numeric,
    ingredientes    int,
    con_existencia  int,
    renglon_absurdo text,
    encender        boolean not null,
    primary key (ronda, menu_item_id)
  );

  -- la ronda abierta (sin aplicar) se rehace; si no hay, se abre otra
  select max(ronda) into v_ronda from public._penda_rec_ronda where aplicado_en is null;
  if v_ronda is null then
    select coalesce(max(ronda), 0) + 1 into v_ronda from public._penda_rec_ronda;
    insert into public._penda_rec_ronda (ronda) values (v_ronda);
  else
    update public._penda_rec_ronda set creado_en = now() where ronda = v_ronda;
    delete from public._penda_rec_ronda_lista where ronda = v_ronda;
  end if;

  insert into public._penda_rec_ronda_lista
    (ronda, menu_item_id, producto, precio, ingredientes, con_existencia,
     renglon_absurdo, encender)
  with
  ing as (
    select m.id as menu_item_id, m.name as producto, coalesce(m.price, 0) as precio,
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
       and not coalesce(m.is_inventory_tracked, false)
  ),
  raras as (
    select menu_item_id,
           string_agg(insumo || ' ' || regexp_replace(round(quantity, 3)::text, '\.?0+$', '')
                      || ' ' || coalesce(unit, '') || ' × RD$'
                      || regexp_replace(round(costo, 2)::text, '\.?0+$', '')
                      || ' = RD$' || to_char(costo_linea, 'FM999,999,990'),
                      ' · ' order by costo_linea desc) as detalle
      from ing
     where costo_linea > greatest(5 * precio, 5000)
     group by menu_item_id
  )
  select v_ronda, g.menu_item_id, g.producto, max(g.precio), count(*),
         count(*) filter (where g.hay), r.detalle,
         count(*) filter (where g.hay) > 0 and r.detalle is null
    from ing g
    left join raras r on r.menu_item_id = g.menu_item_id
   group by g.menu_item_id, g.producto, r.detalle;
end
$$;

create or replace function public._penda_rec_ronda_consumo(p_ronda int)
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
      join public._penda_rec_ronda_lista e on e.menu_item_id = oi.product_id and e.encender and e.ronda = p_ronda
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
      join public._penda_rec_ronda_lista e on e.menu_item_id = oim.menu_item_id and e.encender and e.ronda = p_ronda
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
--   N0  cuántas recetas apagadas entran en esta ronda y cuántas siguen fuera
--   N1  lo que esas recetas gastaron desde el conteo (órdenes, insumos)
--   N2  los 20 insumos que más gastaron, y cómo queda Cocina
--   N4  las que siguen fuera por un renglón absurdo
with
r as (select max(ronda) as n from public._penda_rec_ronda where aplicado_en is null),
l as (select * from public._penda_rec_ronda_lista where ronda = (select n from r)),
c as (select * from public._penda_rec_ronda_consumo((select n from r))),
w as (
  select w.name, w.id from public.warehouses w
   where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and w.name in ('Cocina','Almacen Principal','FoodShop')
),
pi as (
  select c.item_id, sum(c.qty) as consumo, count(distinct c.order_id) as ordenes
    from c group by c.item_id
),
det as (
  select i.name as insumo, i.unit, coalesce(i.cost, 0) as costo, pi.consumo, pi.ordenes,
         coalesce((select st.quantity from public.inventory_stock st
                    where st.item_id = pi.item_id
                      and st.warehouse_id = (select id from w where name = 'Cocina')), 0) as cocina,
         coalesce((select sum(st.quantity) from public.inventory_stock st
                    where st.item_id = pi.item_id
                      and st.warehouse_id in (select id from w where name <> 'Cocina')), 0) as fuera
    from pi join public.inventory_items i on i.id = pi.item_id
)
select seccion, dato, valor from (
  select 0 as orden, 'N0 ronda ' || (select n from r) as seccion,
         case when encender then 'ENTRAN'
              when renglon_absurdo is not null then 'fuera: renglón absurdo (N4)'
              else 'fuera: ningún insumo con existencia' end as dato,
         count(*) || ' · ' || left(string_agg(producto, ' · ' order by producto), 200) as valor,
         count(*)::numeric as peso
    from l group by 3
  union all
  select 1, 'N1 gastado desde el conteo', 'órdenes · insumos',
         (select count(distinct order_id) from c) || ' órdenes · '
         || (select count(distinct item_id) from c) || ' insumos', 0
  union all
  select * from (
    select 2, 'N2 lo que más gastaron', insumo || ' (' || coalesce(unit, '') || ')',
           'gastó ' || regexp_replace(round(consumo, 3)::text, '\.?0+$', '')
           || ' en ' || ordenes || ' órdenes · Cocina '
           || regexp_replace(round(cocina, 2)::text, '\.?0+$', '') || ' → '
           || regexp_replace(round(cocina - consumo
                + least(greatest(consumo - cocina, 0), greatest(fuera, 0)), 2)::text, '\.?0+$', '')
           || case when least(greatest(consumo - cocina, 0), greatest(fuera, 0)) > 0
                   then ' (se pasan ' || regexp_replace(round(least(greatest(consumo - cocina, 0),
                        greatest(fuera, 0)), 2)::text, '\.?0+$', '') || ' del Principal/FoodShop)'
                   else '' end,
           consumo * costo
      from det
     order by consumo * costo desc, consumo desc
     limit 20
  ) t
  union all
  select 4, 'N4 fuera por renglón absurdo', producto, renglon_absurdo, 0
    from l where renglon_absurdo is not null
) x
order by orden, peso desc, dato;
