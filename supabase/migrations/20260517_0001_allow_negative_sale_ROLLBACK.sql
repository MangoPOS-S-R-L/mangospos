-- Rollback de `20260517_0001_allow_negative_sale.sql`.
-- Revierte la función a la versión de 20260516_0015 y deja la columna en
-- su lugar (no se borra para no romper backups recientes que esperan
-- el flag). Si se requiere drop completo de la columna, hacerlo manual.

begin;

-- Restaurar la función original sin el short-circuit por allow_negative_sale.
create or replace function public.fn_recompute_menu_items_availability(
  p_inventory_item_id uuid
)
returns void
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

  for v_menu_item in
    select distinct mi.id, mi.is_active, mi.auto_disabled
    from public.menu_items mi
    join public.recipes r on r.menu_item_id = mi.id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    where ri.inventory_item_id = p_inventory_item_id
      and coalesce(mi.is_inventory_tracked, false) = true
  loop
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
$$;

-- Para eliminar también la columna allow_negative_sale (opcional):
--   alter table public.menu_items drop column if exists allow_negative_sale;

commit;
