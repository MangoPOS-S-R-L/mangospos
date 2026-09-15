-- =============================================================================
-- ROLLBACK de 20260915_0002_consume_unified
--
-- Vuelve consume_inventory_from_order a la versión A (20260901_0006: cascada
-- multi-bodega, SIN modificadores con insumos y SIN devolución de anuladas) y
-- quita el trigger de anulación. El cuerpo de abajo se copió por script desde
-- 20260901_0006, no a mano.
--
-- OJO: si el trigger trg_orders_reconcile_inventory_on_status ya existía antes
-- de aplicar la unificada (20260910_0002 aplicada sin su consumo), este
-- ROLLBACK igual lo quita.
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $guard$
declare
  v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'consume_inventory_from_order'
   limit 1;
  v_src := coalesce(v_src, '');
  if v_src not like '%UNIFICADA 20260915_0002%' then
    raise exception 'La función viva no es la unificada (20260915_0002): no hay nada que revertir. No se tocó nada.';
  end if;
end
$guard$;

drop trigger if exists trg_orders_reconcile_inventory_on_status on public.orders;
drop function if exists public.fn_orders_reconcile_inventory_on_status();

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

commit;

notify pgrst, 'reload schema';
