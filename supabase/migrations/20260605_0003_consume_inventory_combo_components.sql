-- =============================================================================
-- 20260605_0003 — consume_inventory_from_order: descontar componentes de combo
-- =============================================================================
--
-- PROBLEMA QUE RESUELVE
-- ─────────────────────
-- `consume_inventory_from_order` (mig. 20260517_0002) descuenta inventario
-- expandiendo cada línea por la RECETA de su `product_id`:
--   order_items → menu_items → recipes(menu_item_id=product_id) → recipe_ingredients
-- Un COMBO (`menu_items.item_type='combo'`) normalmente NO tiene receta propia,
-- así que vender un combo NO descuenta nada (PRD Ofertas/Combos/Inventario, R3).
-- Los componentes elegidos viven en `order_item_modifiers` (con `menu_item_id`
-- desde 20260605_0002), no en la receta del combo.
--
-- FIX (decisión: cada componente descuenta "como producto normal")
-- ────────────────────────────────────────────────────────────────
-- La función reconciliadora ahora suma DOS rutas de "expected":
--   (1) Productos normales — IGUAL que antes, pero EXCLUYENDO combos
--       (`mi.item_type <> 'combo'`) para que un combo no descuente por su
--       receta propia (evita doble descuento si alguien le pusiera receta).
--   (2) Componentes de combo — por cada línea combo, expande cada modifier con
--       `menu_item_id` vía la receta DEL COMPONENTE, multiplicado por la qty del
--       combo y la qty del modifier:
--         order_items(combo) → order_item_modifiers(menu_item_id)
--           → menu_items(componente) → recipes(menu_item_id=componente)
--           → recipe_ingredients
--       Cada componente se gatea por SU PROPIO `is_inventory_tracked`, igual que
--       si se vendiera suelto. Si el componente no tiene receta o no está
--       rastreado, no descuenta (mismo trato que un producto normal sin receta).
--
-- TIMING / TRIGGERS (sin cambios)
--   - El consumo lo disparan los triggers existentes sobre `order_items`
--     (status/qty/delete) y la confirmación a cocina. Para entonces los
--     modifiers del combo ya están persistidos (se insertan justo tras crear la
--     línea), así que la expansión los ve. NO se agrega trigger sobre
--     `order_item_modifiers` a propósito: invocaría el consumo mientras la línea
--     aún está en draft (antes de enviar a cocina) y descontaría de más.
--   - Editar los componentes de un combo DESPUÉS de enviar a cocina es un caso
--     borde que esta versión no re-reconcilia automáticamente (limitación
--     conocida; la línea-combo no cambia de status/qty al tocar un modifier).
--
-- SEGURIDAD / NO-REGRESIÓN
--   - Productos no-combo: comportamiento IDÉNTICO (la ruta (1) solo añade el
--     guard `<> 'combo'`, que hoy no excluye nada real porque los combos no
--     tienen receta).
--   - Sigue siendo reconciliadora e idempotente: emite el movimiento que cierra
--     el delta (negativo=consume, positivo=devuelve). Cancelar/anular/eliminar
--     la línea-combo devuelve los componentes vía el mismo cálculo de delta.
--   - Doble gate intacto: business_settings.inventory_mode + is_inventory_tracked
--     (este último ahora evaluado sobre el COMPONENTE en la ruta de combo).
--   - Depende de order_item_modifiers.menu_item_id (20260605_0002). Aplicar esa
--     migración ANTES.
-- =============================================================================

begin;

create or replace function public.consume_inventory_from_order(_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
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

  -- Gate por inventory_mode (igual que antes). En 'none' no tocamos stock.
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

  -- Universo de ingredientes a reconciliar: union de los que aparecen en
  -- (1) items normales vivos, (2) componentes de combo vivos, y (3) los que ya
  -- tienen movimientos persistidos para esta orden (capta items
  -- eliminados/anulados que necesitan devolver).
  for v_inventory_item_id in
    select inventory_item_id from (
      -- (1) Productos normales (NO combos).
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
    -- Expected: cuánto debería consumir la orden ahora mismo de este
    -- ingrediente, sumando ruta de productos normales + ruta de componentes.
    select coalesce(sum(q), 0)
      into v_expected
    from (
      -- (1) Productos normales (NO combos).
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

    -- Net consumed: suma de movimientos sign-aware.
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
$$;

comment on function public.consume_inventory_from_order(uuid) is
  'Reconcilia stock vs items vivos de la orden. Expande productos normales por '
  'su receta (excluyendo combos) Y componentes de combo por la receta de cada '
  'componente (order_item_modifiers.menu_item_id). Inserta movement con signo '
  'apropiado: negativo si falta descontar, positivo si sobra (cancelado). '
  'Idempotente — converge al delta cero. Doble gate: is_inventory_tracked '
  '(del producto/componente) + business_settings.inventory_mode.';

commit;
