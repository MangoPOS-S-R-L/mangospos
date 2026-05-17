-- =============================================================================
-- Inventario PRO: Auto-86 (sold-out automático) estilo Toast.
--
-- COMPORTAMIENTO:
--   - Cuando el stock de un insumo cae a 0 (o negativo) y un producto del
--     menú depende de él (vía receta), ese producto queda marcado como
--     `is_active = false` automáticamente. Desaparece del catálogo del
--     cajero porque las queries ya filtran por `is_active = true`.
--   - Cuando el stock vuelve a > 0 (compra, recepción, transferencia),
--     el producto se REACTIVA automáticamente — pero solo si fue
--     desactivado por auto-86 (no si el admin lo apagó manualmente).
--
-- DISEÑO:
--   - Nuevo flag `menu_items.auto_disabled` distingue auto-86 vs apagado
--     manual. La reactivación solo toca rows con `auto_disabled = true`.
--   - Función `fn_recompute_menu_items_availability(inventory_item_id)`
--     calcula MIN(stock/per_unit_qty) sobre todas las recetas de cada
--     producto que usa ese insumo. Cubre 1:1 (Loyverse) y multi-ingrediente.
--   - Trigger AFTER INSERT en `inventory_movements` dispara la función
--     con el `item_id` afectado.
--
-- NO TOCA:
--   - Productos con `is_inventory_tracked = false` (catálogo bebidas/etc.
--     no inventariadas). Esos quedan siempre disponibles.
--   - Productos en modo `inventory_mode = 'none'` — no hay tracking activo
--     para esos negocios.
--
-- IDEMPOTENTE: CREATE OR REPLACE en todo.
-- =============================================================================

begin;

-- 1. Columna que distingue auto-86 de apagado manual.
alter table public.menu_items
  add column if not exists auto_disabled boolean not null default false;

comment on column public.menu_items.auto_disabled is
  'Si true, el producto fue desactivado por auto-86 (stock = 0). Al volver '
  'stock, se reactiva automáticamente. Si false y is_active = false, '
  'es desactivación manual del admin — auto-86 no la toca.';

-- 2. Función central: recalcula availability para todos los menu_items que
--    usan el inventory_item afectado.
create or replace function public.fn_recompute_menu_items_availability(
  p_inventory_item_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_menu_item record;
  v_available numeric;
begin
  if p_inventory_item_id is null then
    return;
  end if;

  -- Cada menu_item que usa este insumo (vía recetas) y está tracked.
  for v_menu_item in
    select distinct mi.id, mi.is_active, mi.auto_disabled
    from public.menu_items mi
    join public.recipes r on r.menu_item_id = mi.id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    where ri.inventory_item_id = p_inventory_item_id
      and coalesce(mi.is_inventory_tracked, false) = true
  loop
    -- Available = min sobre todos los ingredientes de
    --   floor(sum(stock_del_ingrediente) / per_unit_qty).
    -- Si CUALQUIER ingrediente no alcanza para producir 1 unidad,
    -- el producto no se puede vender → 0.
    select min(
      floor(
        coalesce((
          select sum(ist.quantity)
          from public.inventory_stock ist
          where ist.item_id = ri2.inventory_item_id
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
      -- Stock agotado → auto-disable. Solo si está actualmente activo
      -- (no pisar productos ya desactivados manualmente).
      if v_menu_item.is_active = true then
        update public.menu_items
        set is_active = false, auto_disabled = true
        where id = v_menu_item.id;
      end if;
    else
      -- Stock disponible → reactivar SOLO si fue auto-86 antes.
      -- Productos que el admin apagó a mano (auto_disabled = false)
      -- NO se reactivan automáticamente.
      if v_menu_item.auto_disabled = true and v_menu_item.is_active = false then
        update public.menu_items
        set is_active = true, auto_disabled = false
        where id = v_menu_item.id;
      end if;
    end if;
  end loop;
end;
$$;

comment on function public.fn_recompute_menu_items_availability(uuid) is
  'Auto-86: recalcula availability de productos que dependen del insumo. '
  'Si stock = 0 → is_active = false + auto_disabled = true. Si stock > 0 '
  'y auto_disabled = true → reactiva. No toca productos desactivados '
  'manualmente (auto_disabled = false con is_active = false).';

-- 3. Trigger en inventory_movements: cada vez que entra/sale stock,
--    recalcular menu_items que dependen del insumo.
create or replace function public.fn_trigger_recompute_menu_availability()
returns trigger
language plpgsql
as $$
begin
  perform public.fn_recompute_menu_items_availability(new.item_id);
  return new;
end;
$$;

drop trigger if exists trg_movements_recompute_menu_availability
  on public.inventory_movements;
create trigger trg_movements_recompute_menu_availability
  after insert on public.inventory_movements
  for each row
  execute function public.fn_trigger_recompute_menu_availability();

-- 4. Backfill: para negocios que ya tenían stock = 0 antes de esta migración.
--    Recorre todos los inventory_items y recalcula availability.
do $$
declare
  v_item record;
begin
  for v_item in
    select distinct ri.inventory_item_id as id
    from public.recipe_ingredients ri
    where ri.inventory_item_id is not null
  loop
    perform public.fn_recompute_menu_items_availability(v_item.id);
  end loop;
end $$;

commit;
