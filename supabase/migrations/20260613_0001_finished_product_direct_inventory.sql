-- =============================================================================
-- 20260613_0001 — Inventario directo de productos TERMINADOS (sin receta)
-- =============================================================================
--
-- PROBLEMA
-- ────────
-- Hoy `consume_inventory_from_order` SOLO deduce productos que tienen una
-- RECETA (inner join recipes). Para que una cerveza/licor/agua (producto
-- terminado vendido por unidad) deduzca stock, el admin tenía que marcarla
-- "Inventariable", lo que creaba un self-recipe 1:1 oculto. Frágil y confuso;
-- y para bundles ("4x3 Heineken" hechos a mano) el 1:1 deduce 1, no 4.
--
-- SOLUCIÓN (arquitectura limpia)
-- ──────────────────────────────
--   1. `menu_items.inventory_item_id`: link DIRECTO producto terminado ↔ su
--      item de inventario.
--   2. `consume_inventory_from_order`: 3ª ruta — productos rastreados, SIN
--      receta, con `inventory_item_id` → deducen ese item × qty. Sin doble
--      conteo: la ruta directa exige `not exists (recipe)`, así que un
--      producto cae en UNA sola ruta (receta O directa).
--   3. (companion, migración aparte) `fn_menu_item_set_inventory_tracked`
--      setea el link directo en vez del self-recipe.
--
-- COMPAT: productos existentes con receta (incluido el self-recipe 1:1 de
-- Gatorade) siguen por la ruta de recetas, intactos. Esta migración es
-- ADITIVA: sin `inventory_item_id` poblado, la ruta nueva no toca nada.
--
-- ⚠️ BASE = consume_inventory_from_order VIVO (versión con combos), no el repo.
-- Verificado 2026-06-13 con pg_get_functiondef. Reproduce ese cuerpo y solo
-- AÑADE la ruta directa (1b) al universo y al expected.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Link directo producto terminado → item de inventario.
-- ---------------------------------------------------------------------------
alter table public.menu_items
  add column if not exists inventory_item_id uuid references public.inventory_items(id);

comment on column public.menu_items.inventory_item_id is
  'Producto TERMINADO: item de inventario del que descuenta stock al venderse '
  '(cerveza/licor/agua). Vía directa sin receta. NULL = no aplica (usa receta '
  'o no se inventaría). consume_inventory_from_order deduce este item × qty.';

create index if not exists idx_menu_items_inventory_item
  on public.menu_items(inventory_item_id)
  where inventory_item_id is not null;

-- ---------------------------------------------------------------------------
-- 2. consume_inventory_from_order: VIVO + ruta directa (1b) de terminados.
-- ---------------------------------------------------------------------------
create or replace function public.consume_inventory_from_order(_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_main_warehouse_id uuid;
  v_business_id uuid;
  v_mode text;
  v_inventory_item_id uuid;
  v_expected numeric;
  v_net_consumed numeric;
  v_delta numeric;
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
    into v_main_warehouse_id
  from public.warehouses w
  where w.business_id = v_business_id
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_main_warehouse_id is null then
    return;
  end if;

  -- Universo de ingredientes a reconciliar.
  for v_inventory_item_id in
    select inventory_item_id from (
      -- (1) Productos normales con receta (NO combos).
      select distinct i.inventory_item_id
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
      union
      -- (1b) Productos TERMINADOS con link directo (SIN receta).
      select distinct mi.inventory_item_id
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
      union
      -- (2) Componentes de combo (vía order_item_modifiers.menu_item_id).
      select distinct i.inventory_item_id
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
      union
      -- (3) Ingredientes con movimientos previos para esta orden.
      select distinct im.item_id
      from public.inventory_movements im
      where im.reference_id = _order_id
        and im.reference_type = 'order'
        and im.movement_type = 'sale'
    ) u
    where u.inventory_item_id is not null
  loop
    -- Expected: ruta normal + ruta terminado-directo + ruta combos.
    select coalesce(sum(q), 0)
      into v_expected
    from (
      -- (1) Productos normales con receta (NO combos).
      select i.quantity * coalesce(oi.qty, oi.quantity::numeric, 0) as q
      from public.order_items oi
      join public.menu_items mi on mi.id = oi.product_id
      join public.recipes r on r.menu_item_id = oi.product_id
      join public.recipe_ingredients i on i.recipe_id = r.id
      where oi.order_id = _order_id
        and i.inventory_item_id = v_inventory_item_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(mi.is_inventory_tracked, false) = true
        and coalesce(mi.item_type, '') <> 'combo'
      union all
      -- (1b) Producto TERMINADO directo: qty del item linkeado (× 1).
      select coalesce(oi.qty, oi.quantity::numeric, 0) as q
      from public.order_items oi
      join public.menu_items mi on mi.id = oi.product_id
      where oi.order_id = _order_id
        and mi.inventory_item_id = v_inventory_item_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(mi.is_inventory_tracked, false) = true
        and coalesce(mi.item_type, '') <> 'combo'
        and not exists (
          select 1 from public.recipes r where r.menu_item_id = mi.id
        )
      union all
      -- (2) Componentes de combo: receta del componente × qty modifier × qty combo.
      select i.quantity
             * coalesce(oim.qty, 1)
             * coalesce(oi.qty, oi.quantity::numeric, 0) as q
      from public.order_items oi
      join public.menu_items combo_mi
        on combo_mi.id = oi.product_id and combo_mi.item_type = 'combo'
      join public.order_item_modifiers oim
        on oim.item_id = oi.id and oim.menu_item_id is not null
      join public.menu_items comp_mi on comp_mi.id = oim.menu_item_id
      join public.recipes r on r.menu_item_id = oim.menu_item_id
      join public.recipe_ingredients i on i.recipe_id = r.id
      where oi.order_id = _order_id
        and i.inventory_item_id = v_inventory_item_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(comp_mi.is_inventory_tracked, false) = true
    ) e;

    select coalesce(-sum(im.quantity), 0)
      into v_net_consumed
    from public.inventory_movements im
    where im.reference_id = _order_id
      and im.reference_type = 'order'
      and im.movement_type = 'sale'
      and im.item_id = v_inventory_item_id;

    v_delta := v_expected - v_net_consumed;

    if v_delta = 0 then
      continue;
    end if;

    v_note := case when v_delta > 0 then 'Auto-consumo por venta'
                   else 'Devolución por cancelación/edición' end;

    insert into public.inventory_movements (
      business_id,
      warehouse_id,
      item_id,
      movement_type,
      quantity,
      reference_id,
      reference_type,
      notes
    )
    values (
      v_business_id,
      v_main_warehouse_id,
      v_inventory_item_id,
      'sale',
      -v_delta,
      _order_id,
      'order',
      v_note
    );
  end loop;
end;
$function$;

commit;
