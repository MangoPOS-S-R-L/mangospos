-- =============================================================================
-- Toggle por producto: permitir venta cuando el stock llega a 0 o negativo.
--
-- CONTEXTO:
--   La migración 20260516_0015 introdujo `auto-86`: cuando un insumo se
--   agota, el trigger desactiva (is_active=false) los menu_items que lo
--   consumen para que el cajero no pueda venderlos. Esto sirve para
--   bares/restaurantes con conteo estricto, pero NO para negocios que
--   quieren seguir vendiendo "en negativo" hasta la próxima reposición
--   (los faltantes se saldan automáticamente cuando llegue la compra).
--
-- SOLUCIÓN:
--   Flag por menu_item `allow_negative_sale`. Si está activo, el auto-86
--   NO desactiva el producto al llegar a 0. El badge "Agotado" en la UI
--   sigue mostrándose para que el cajero sea consciente.
--
-- IDEMPOTENTE: ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE FUNCTION.
-- =============================================================================

begin;

-- 1. Columna boolean en menu_items. Default false = comportamiento previo
--    (auto-86 desactiva al agotarse). Admin puede activar por producto
--    desde el formulario de edición.
alter table public.menu_items
  add column if not exists allow_negative_sale boolean not null default false;

comment on column public.menu_items.allow_negative_sale is
  'Si true, el auto-86 NO desactiva este producto cuando su stock llega '
  'a 0. El cajero puede seguir vendiéndolo (stock queda negativo, la '
  'próxima compra/recepción salda la deuda). Default false = ocultar al '
  'agotarse (comportamiento legacy).';

-- 2. Reemplazar fn_recompute_menu_items_availability para respetar el flag.
--    Misma firma y semántica que la versión de 20260516_0015, con un
--    short-circuit cuando allow_negative_sale = true.
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
    select distinct
      mi.id,
      mi.is_active,
      mi.auto_disabled,
      mi.allow_negative_sale
    from public.menu_items mi
    join public.recipes r on r.menu_item_id = mi.id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    where ri.inventory_item_id = p_inventory_item_id
      and coalesce(mi.is_inventory_tracked, false) = true
  loop
    -- Productos que permiten venta en negativo: nunca los auto-desactivamos.
    -- El badge "Agotado" en la UI alerta al cajero; el conteo sigue corriendo
    -- en inventory_stock (puede ir negativo) y se salda con la próxima compra.
    if v_menu_item.allow_negative_sale = true then
      -- Si veníamos de un auto-86 anterior (antes de que se activara el
      -- flag), reactivamos para que vuelva al menú.
      if v_menu_item.auto_disabled = true and v_menu_item.is_active = false then
        update public.menu_items
        set is_active = true, auto_disabled = false
        where id = v_menu_item.id;
      end if;
      continue;
    end if;

    -- Comportamiento legacy: calcula availability respetando todos los
    -- ingredientes y desactiva si alguno se agotó.
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

comment on function public.fn_recompute_menu_items_availability(uuid) is
  'Auto-86 con respeto al flag allow_negative_sale: si el producto permite '
  'venta en negativo, NO se auto-desactiva al llegar a 0. Si no, sigue el '
  'comportamiento histórico (desactiva al agotarse, reactiva al reponer).';

commit;
