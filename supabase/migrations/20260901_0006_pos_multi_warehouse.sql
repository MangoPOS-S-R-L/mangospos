-- =============================================================================
-- Varias bodegas alimentando el punto de venta: suma para mostrar, cascada
-- para descontar.
--
-- LO PEDIDO (dueño, 2026-08-31):
--   Poder marcar «Mostrar los productos de esta bodega en el punto de venta»
--   en VARIAS bodegas a la vez. El grid muestra la SUMA de las marcadas y la
--   venta descuenta de la principal primero, y cuando se acaba, de la
--   siguiente.
--
-- POR QUÉ ESTO NO ES UN `drop index` Y YA:
--   La reconciliación del consumo trabaja por par (insumo, bodega) y hasta
--   ahora resolvía UNA bodega por producto. Si se limita a permitir dos
--   marcadas sin tocar el reparto, pasa esto: la barra tiene 6, se venden 10,
--   la resolución salta a la nevera y la reconciliación DEVUELVE los 6 a la
--   barra y descuenta los 10 de la nevera. La nevera queda en -10 y la barra
--   con existencia que ya se vendió.
--
--   Así que el consumo aprende a repartir: 6 de la barra y 4 de la nevera,
--   en el orden que corresponde.
--
-- ENTREGA:
--   1. Se levanta el índice único: varias bodegas pueden estar marcadas.
--   2. `fn_resolve_area_warehouse` — la bodega del ÁREA del producto, o null.
--      Se separa para poder distinguir "resolvió por área" de "cayó al pozo".
--   3. `fn_pos_stock_warehouses` — el conjunto ORDENADO de bodegas que ve un
--      producto: [la de su área] si tiene, si no las marcadas en orden, y
--      null = todas (comportamiento histórico).
--   4. `v_menu_items_stock` y el auto-86 suman sobre ese conjunto.
--   5. `consume_inventory_from_order` reparte en cascada sobre ese conjunto.
--
-- EL ORDEN DE LA CASCADA: la principal primero, después por antigüedad.
--   `order by w.is_main desc, w.created_at asc nulls first, w.id asc` — el
--   mismo criterio que ya usaba la bodega por defecto, así que "descuenta del
--   principal y luego del otro" sale solo.
--
-- CÓMO SE REPARTE, y por qué así:
--   El cupo de cada bodega NO es su existencia actual, es
--   `existencia + lo que ESTA orden ya le sacó`. O sea, la existencia como si
--   esta orden no hubiera pasado. Sin eso, cada vez que se recalcula la orden
--   el reparto se correría solo (la bodega ya descontada parecería más vacía)
--   y los movimientos rebotarían entre bodegas.
--
--   Si lo pedido supera el cupo de todas, el EXCEDENTE va a la última de la
--   cascada, que es la que queda en negativo. Es deliberado: alguien tiene
--   que quedar debiendo, y que sea siempre la misma hace el faltante legible.
--
--   Otras órdenes SÍ mueven el cupo entre recálculos, así que el reparto de
--   una orden abierta puede ajustarse mientras esté abierta. Es correcto —
--   refleja la existencia real— pero deja rastro en el kardex.
--
-- CON TODO APAGADO NO CAMBIA NADA: sin bandera de áreas y sin bodegas
--   marcadas, el conjunto es null, la vista suma todas las bodegas y el
--   consumo cae en la bodega por defecto. Idéntico a hoy.
--
-- REQUIERE: 20260901_0002, 0004 y 0005.
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Varias bodegas pueden estar marcadas
-- ---------------------------------------------------------------------------

drop index if exists public.uq_warehouses_pos_source;

create index if not exists idx_warehouses_pos_source
  on public.warehouses (business_id)
  where shows_in_pos;

comment on column public.warehouses.shows_in_pos is
  'El punto de venta suma la existencia de esta bodega y descuenta de ella. '
  'Puede haber VARIAS por negocio: el grid muestra la suma y la venta '
  'descuenta en cascada, la principal primero. Los productos ruteados a un '
  'área de producción no pasan por acá: salen de la bodega de su área.';

-- ---------------------------------------------------------------------------
-- 2. La bodega del área, o null
-- ---------------------------------------------------------------------------

create or replace function public.fn_resolve_area_warehouse(
  p_business_id  uuid,
  p_menu_item_id uuid
) returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when coalesce(
      (select bs.warehouse_sections_enabled
         from public.business_settings bs
        where bs.business_id = p_business_id),
      false
    ) then (
      select w.id
        from public.warehouses w
        join public.print_areas pa on pa.id = w.production_area_id
       where w.business_id = p_business_id
         and coalesce(w.is_active, true)
         and w.warehouse_type = 'production'
         and pa.id in (
           select mipa.print_area_id
             from public.menu_item_print_areas mipa
            where mipa.menu_item_id = p_menu_item_id
           union all
           select pa2.id
             from public.menu_items mi
             join public.print_areas pa2
               on pa2.business_id = mi.business_id
              and pa2.code = mi.print_area_code
            where mi.id = p_menu_item_id
              and mi.print_area_code is not null
              and not exists (
                select 1 from public.menu_item_print_areas x
                 where x.menu_item_id = p_menu_item_id
              )
         )
       order by coalesce(pa.display_order, 0) asc, pa.name asc, w.id asc
       limit 1
    )
  end;
$$;

comment on function public.fn_resolve_area_warehouse(uuid, uuid) is
  'La bodega del área de producción de un producto, o NULL si no tiene área, '
  'si el área no tiene bodega, o si la bandera warehouse_sections_enabled '
  'está apagada. Separada de fn_resolve_consumption_warehouse para poder '
  'distinguir "resolvió por área" de "cayó en las bodegas del punto de '
  'venta".';

-- ---------------------------------------------------------------------------
-- 3. El conjunto ORDENADO de bodegas que ve un producto
-- ---------------------------------------------------------------------------

create or replace function public.fn_pos_stock_warehouses(
  p_business_id  uuid,
  p_menu_item_id uuid
) returns uuid[]
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    -- (1) Tiene área: una sola bodega, la suya.
    when public.fn_resolve_area_warehouse(p_business_id, p_menu_item_id)
         is not null
      then array[
        public.fn_resolve_area_warehouse(p_business_id, p_menu_item_id)
      ]
    -- (2) Las marcadas para el punto de venta, EN ORDEN DE CASCADA.
    when exists (
      select 1 from public.warehouses w
       where w.business_id = p_business_id
         and coalesce(w.is_active, true) and w.shows_in_pos
    ) then (
      select array_agg(w.id order by w.is_main desc,
                                    w.created_at asc nulls first,
                                    w.id asc)
        from public.warehouses w
       where w.business_id = p_business_id
         and coalesce(w.is_active, true)
         and w.shows_in_pos
    )
    -- (3) NULL = todas las bodegas. El comportamiento de siempre.
  end;
$$;

comment on function public.fn_pos_stock_warehouses(uuid, uuid) is
  'Bodegas de las que sale un producto, en orden de cascada. Un elemento si '
  'resuelve por área; las marcadas shows_in_pos si no; NULL = todas (sin '
  'nada configurado). Lo usan la vista v_menu_items_stock, el auto-86 y '
  'consume_inventory_from_order: mostrar y descontar salen del mismo lugar.';

grant execute on function public.fn_resolve_area_warehouse(uuid, uuid)
  to authenticated, service_role;
grant execute on function public.fn_pos_stock_warehouses(uuid, uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. fn_resolve_consumption_warehouse: se mantiene, construida sobre las dos
--    nuevas. Sigue devolviendo UNA bodega — la primera de la cascada — para
--    quien solo necesite un destino.
-- ---------------------------------------------------------------------------

create or replace function public.fn_resolve_consumption_warehouse(
  p_business_id         uuid,
  p_menu_item_id        uuid,
  p_default_warehouse_id uuid
) returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    (public.fn_pos_stock_warehouses(p_business_id, p_menu_item_id))[1],
    p_default_warehouse_id
  );
$$;

-- ---------------------------------------------------------------------------
-- 5. La vista: suma sobre el conjunto
-- ---------------------------------------------------------------------------

create or replace view public.v_menu_items_stock
with (security_invoker = on) as
with recipe_ingredient_counts as (
  select r.menu_item_id, count(*) as ingredient_count
  from public.recipes r
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where ri.inventory_item_id is not null
    and coalesce(ri.quantity, 0::numeric) > 0::numeric
  group by r.menu_item_id
), one_ingredient_recipes as (
  select r.menu_item_id, ri.inventory_item_id, ri.quantity as per_unit_qty
  from public.recipes r
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  join recipe_ingredient_counts c on c.menu_item_id = r.menu_item_id
  where c.ingredient_count = 1
    and ri.inventory_item_id is not null
    and coalesce(ri.quantity, 0::numeric) > 0::numeric
), item_links as (
  select menu_item_id, inventory_item_id, per_unit_qty
  from one_ingredient_recipes
  union all
  select mi_1.id, mi_1.inventory_item_id, 1::numeric
  from public.menu_items mi_1
  where mi_1.inventory_item_id is not null
    and not exists (
      select 1 from public.recipes r where r.menu_item_id = mi_1.id
    )
)
select
  mi.id                 as menu_item_id,
  il.inventory_item_id,
  ii.unit,
  floor(coalesce(sum(ist.quantity), 0::numeric)
        / nullif(il.per_unit_qty, 0::numeric)) as available_units,
  coalesce(sum(ist.quantity), 0::numeric)      as raw_ingredient_stock,
  il.per_unit_qty                              as ingredient_per_unit
from public.menu_items mi
join item_links il on il.menu_item_id = mi.id
join public.inventory_items ii on ii.id = il.inventory_item_id
-- Las bodegas que ve este producto. Se resuelve UNA vez por fila.
left join lateral (
  select public.fn_pos_stock_warehouses(mi.business_id, mi.id) as ids
) ws on true
left join public.inventory_stock ist
  on ist.item_id = il.inventory_item_id
 -- ids NULL = negocio sin nada configurado: suma todas, como siempre.
 and (ws.ids is null or ist.warehouse_id = any(ws.ids))
where coalesce(mi.is_inventory_tracked, false) = true
group by mi.id, il.inventory_item_id, ii.unit, il.per_unit_qty;

grant select on public.v_menu_items_stock to authenticated;

comment on view public.v_menu_items_stock is
  'Existencia disponible por producto del menú, sumada sobre las bodegas que '
  'le corresponden: la de su área si tiene, las marcadas para el punto de '
  'venta si no, todas si el negocio no configuró nada. Mismo conjunto que '
  'usa consume_inventory_from_order para descontar.';

-- ---------------------------------------------------------------------------
-- 6. El auto-86: mismo conjunto
-- ---------------------------------------------------------------------------

create or replace function public.fn_recompute_menu_items_availability(
  p_inventory_item_id uuid
) returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_menu_item record;
  v_available numeric;
  v_ids uuid[];
begin
  if p_inventory_item_id is null then
    return;
  end if;

  for v_menu_item in
    select distinct
      mi.id, mi.business_id, mi.is_active, mi.auto_disabled,
      mi.allow_negative_sale
    from public.menu_items mi
    join public.recipes r on r.menu_item_id = mi.id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    where ri.inventory_item_id = p_inventory_item_id
      and coalesce(mi.is_inventory_tracked, false) = true
  loop
    -- Productos que permiten venta en negativo: nunca los auto-desactivamos.
    if v_menu_item.allow_negative_sale = true then
      if v_menu_item.auto_disabled = true and v_menu_item.is_active = false then
        update public.menu_items
        set is_active = true, auto_disabled = false
        where id = v_menu_item.id;
      end if;
      continue;
    end if;

    -- El MISMO conjunto que ve el grid y del que descuenta la venta. NULL =
    -- todas las bodegas, que es el comportamiento histórico.
    v_ids := public.fn_pos_stock_warehouses(
      v_menu_item.business_id, v_menu_item.id);

    select min(
      floor(
        coalesce((
          select sum(ist.quantity)
          from public.inventory_stock ist
          where ist.item_id = ri2.inventory_item_id
            and (v_ids is null or ist.warehouse_id = any(v_ids))
        ), 0) / nullif(ri2.quantity, 0)
      )
    )::numeric
      into v_available
    from public.recipes r2
    join public.recipe_ingredients ri2 on ri2.recipe_id = r2.id
    where r2.menu_item_id = v_menu_item.id
      and ri2.inventory_item_id is not null
      and coalesce(ri2.quantity, 0) > 0;

    if v_available is null or v_available <= 0 then
      if v_menu_item.is_active = true then
        update public.menu_items
        set is_active = false, auto_disabled = true
        where id = v_menu_item.id;
      end if;
    else
      if v_menu_item.auto_disabled = true and v_menu_item.is_active = false then
        update public.menu_items
        set is_active = true, auto_disabled = false
        where id = v_menu_item.id;
      end if;
    end if;
  end loop;
end;
$function$;

comment on function public.fn_recompute_menu_items_availability(uuid) is
  'Auto-86 sobre el mismo conjunto de bodegas que ve el grid. NO cubre '
  'productos terminados con link directo sin receta (limitación anterior).';

-- ---------------------------------------------------------------------------
-- 7. El consumo, con reparto en cascada
-- ---------------------------------------------------------------------------

create or replace function public.consume_inventory_from_order(_order_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_default_warehouse_id uuid;
  v_business_id uuid;
  v_mode text;
  v_pool uuid[];
  v_pair record;
  v_note text;
begin
  select ts.business_id
    into v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  where o.id = _order_id
  limit 1;

  if v_business_id is null then
    return;
  end if;

  select coalesce(inventory_mode, 'none')
    into v_mode
  from public.business_settings
  where business_id = v_business_id;

  if coalesce(v_mode, 'none') = 'none' then
    return;
  end if;

  select w.id
    into v_default_warehouse_id
  from public.warehouses w
  where w.business_id = v_business_id
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_default_warehouse_id is null then
    return;
  end if;

  -- La cascada: las bodegas marcadas, la principal primero. Si no hay
  -- ninguna marcada, la cascada es la bodega de siempre y todo se comporta
  -- como antes.
  select array_agg(w.id order by w.is_main desc,
                                 w.created_at asc nulls first,
                                 w.id asc)
    into v_pool
  from public.warehouses w
  where w.business_id = v_business_id
    and coalesce(w.is_active, true)
    and w.shows_in_pos;

  if v_pool is null or array_length(v_pool, 1) is null then
    v_pool := array[v_default_warehouse_id];
  end if;

  for v_pair in
    with expected_rows as (
      -- (1) Productos normales con receta (NO combos).
      select
        i.inventory_item_id,
        oi.product_id                                   as menu_item_id,
        null::uuid                                      as fallback_menu_item_id,
        i.quantity * coalesce(oi.qty, oi.quantity::numeric, 0) as q
      from public.order_items oi
      join public.menu_items mi on mi.id = oi.product_id
      join public.recipes r on r.menu_item_id = oi.product_id
      join public.recipe_ingredients i on i.recipe_id = r.id
      where oi.order_id = _order_id
        and oi.product_id is not null
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(mi.is_inventory_tracked, false) = true
        and coalesce(mi.item_type, '') <> 'combo'
        and i.inventory_item_id is not null

      union all

      -- (1b) Productos TERMINADOS con link directo (SIN receta).
      select
        mi.inventory_item_id,
        oi.product_id,
        null::uuid,
        coalesce(oi.qty, oi.quantity::numeric, 0)
      from public.order_items oi
      join public.menu_items mi on mi.id = oi.product_id
      where oi.order_id = _order_id
        and oi.product_id is not null
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(mi.is_inventory_tracked, false) = true
        and mi.inventory_item_id is not null
        and coalesce(mi.item_type, '') <> 'combo'
        and not exists (
          select 1 from public.recipes r where r.menu_item_id = mi.id
        )

      union all

      -- (2) Componentes de combo. El área la manda el COMPONENTE; si no
      -- tiene, se prueba con la del combo.
      select
        i.inventory_item_id,
        oim.menu_item_id,
        oi.product_id,
        i.quantity * coalesce(oim.qty, 1)
                   * coalesce(oi.qty, oi.quantity::numeric, 0)
      from public.order_items oi
      join public.menu_items combo_mi
        on combo_mi.id = oi.product_id and combo_mi.item_type = 'combo'
      join public.order_item_modifiers oim
        on oim.item_id = oi.id and oim.menu_item_id is not null
      join public.menu_items comp_mi on comp_mi.id = oim.menu_item_id
      join public.recipes r on r.menu_item_id = oim.menu_item_id
      join public.recipe_ingredients i on i.recipe_id = r.id
      where oi.order_id = _order_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(comp_mi.is_inventory_tracked, false) = true
        and i.inventory_item_id is not null
    ),
    rows_resolved as (
      select
        er.inventory_item_id,
        er.q,
        coalesce(
          public.fn_resolve_area_warehouse(v_business_id, er.menu_item_id),
          public.fn_resolve_area_warehouse(
            v_business_id, er.fallback_menu_item_id)
        ) as area_wid
      from expected_rows er
    ),
    -- Lo que sale de una bodega concreta porque el producto tiene área.
    expected_area as (
      select inventory_item_id, area_wid as warehouse_id, sum(q) as qty
      from rows_resolved
      where area_wid is not null
      group by 1, 2
    ),
    -- Lo que no tiene área y hay que repartir en la cascada.
    expected_pool as (
      select inventory_item_id, sum(q) as qty
      from rows_resolved
      where area_wid is null
      group by 1
    ),
    -- Lo que ESTA orden ya movió, por par. Es lo que la hace idempotente.
    already as (
      select
        im.item_id      as inventory_item_id,
        im.warehouse_id,
        coalesce(-sum(im.quantity), 0) as qty
      from public.inventory_movements im
      where im.reference_id = _order_id
        and im.reference_type = 'order'
        and im.movement_type = 'sale'
      group by 1, 2
    ),
    -- Cupo de cada bodega de la cascada: la existencia COMO SI esta orden no
    -- hubiera pasado, menos lo que ya se reservó por área en esa bodega.
    pool_cap as (
      select
        p.inventory_item_id,
        u.wid,
        u.ord,
        greatest(0,
          coalesce((
            select s.quantity from public.inventory_stock s
             where s.item_id = p.inventory_item_id and s.warehouse_id = u.wid
          ), 0)
          + coalesce((
            select a.qty from already a
             where a.inventory_item_id = p.inventory_item_id
               and a.warehouse_id = u.wid
          ), 0)
          - coalesce((
            select ea.qty from expected_area ea
             where ea.inventory_item_id = p.inventory_item_id
               and ea.warehouse_id = u.wid
          ), 0)
        ) as cap,
        p.qty as needed
      from expected_pool p
      cross join lateral unnest(v_pool) with ordinality as u(wid, ord)
    ),
    -- La cascada propiamente dicha: cada bodega toma lo que puede de lo que
    -- quedó, y la última absorbe el excedente (es la que queda debiendo).
    pool_final as (
      select
        inventory_item_id,
        wid as warehouse_id,
        greatest(0, least(cap, needed - prev_cap))
        + case when ord = last_ord and needed > total_cap
               then needed - total_cap else 0 end as qty
      from (
        select
          c.*,
          coalesce(sum(c.cap) over (
            partition by c.inventory_item_id order by c.ord
            rows between unbounded preceding and 1 preceding), 0) as prev_cap,
          sum(c.cap) over (partition by c.inventory_item_id)      as total_cap,
          max(c.ord) over (partition by c.inventory_item_id)      as last_ord
        from pool_cap c
      ) w
    ),
    -- A dónde tiene que llegar cada par al final de la reconciliación.
    desired as (
      select inventory_item_id, warehouse_id, sum(qty) as qty
      from (
        select inventory_item_id, warehouse_id, qty from expected_area
        union all
        select inventory_item_id, warehouse_id, qty from pool_final
      ) z
      where warehouse_id is not null and qty <> 0
      group by 1, 2
    )
    select
      coalesce(d.inventory_item_id, a.inventory_item_id) as item_id,
      coalesce(d.warehouse_id, a.warehouse_id)           as warehouse_id,
      coalesce(d.qty, 0) - coalesce(a.qty, 0)            as delta
    from desired d
    full outer join already a
      on a.inventory_item_id = d.inventory_item_id
     and a.warehouse_id      = d.warehouse_id
  loop
    if v_pair.delta = 0
       or v_pair.item_id is null
       or v_pair.warehouse_id is null then
      continue;
    end if;

    v_note := case when v_pair.delta > 0 then 'Auto-consumo por venta'
                   else 'Devolución por cancelación/edición' end;

    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type,
      quantity, reference_id, reference_type, notes
    )
    values (
      v_business_id, v_pair.warehouse_id, v_pair.item_id, 'sale',
      -v_pair.delta, _order_id, 'order', v_note
    );
  end loop;
end;
$function$;

comment on function public.consume_inventory_from_order(uuid) is
  'Reconcilia el consumo de una orden. Los productos con área salen de la '
  'bodega de su área; el resto se REPARTE EN CASCADA sobre las bodegas '
  'marcadas para el punto de venta, la principal primero, y la última de la '
  'cascada absorbe lo que falte. Idempotente: sólo escribe la diferencia '
  'contra lo ya movido, y el cupo de cada bodega se calcula como si esta '
  'orden no hubiera pasado, para que recalcular no corra el reparto.';

commit;
