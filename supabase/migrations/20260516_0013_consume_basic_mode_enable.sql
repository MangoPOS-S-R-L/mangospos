-- =============================================================================
-- Inventario: habilitar auto-descuento en modo `basic` (Loyverse-style).
--
-- DECISION ANTERIOR (migración 0005):
--   `consume_inventory_from_order` abortaba early si `inventory_mode != 'advanced'`.
--   La idea era que en modo `basic` el admin registrara entradas/salidas a mano.
--
-- DECISION NUEVA (esta migración):
--   El admin nos pidió comportamiento estilo Loyverse: cada producto del menú
--   tiene stock simple, y al vender se descuenta automáticamente. La
--   infraestructura para esto YA EXISTE:
--     - `fn_menu_item_set_inventory_tracked` crea un `inventory_item` 1:1
--       por producto + una `recipe` con qty=1.
--     - `consume_inventory_from_order` ya descuenta vía recetas.
--   El único bloqueo era el gate por modo. Esta migración lo abre para basic.
--
-- NUEVO GATE:
--     mode = 'none'   → abort. El negocio no usa inventario en absoluto.
--     mode = 'basic'  → procede. Descuenta vía recetas 1:1 auto-creadas.
--     mode = 'advanced' → procede. Descuenta vía recetas custom.
--
--   El doble filtro por `menu_items.is_inventory_tracked = true` sigue intacto:
--   solo productos con tracking opt-in se descuentan. Productos sin tracking
--   se venden sin tocar inventario (caso bebidas embotelladas que no tienes
--   en stock formal, por ejemplo).
--
-- IDEMPOTENTE: CREATE OR REPLACE.
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
  v_ingredient record;
  v_consumed numeric;
  v_delta numeric;
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

  -- Gate por inventory_mode. Solo abortamos cuando el modo es 'none' (o
  -- está sin configurar). Tanto 'basic' como 'advanced' descuentan stock.
  -- En basic, la receta es 1:1 auto-creada al activar tracking en el
  -- producto. En advanced, el admin define recetas custom.
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

  for v_ingredient in
    select
      i.inventory_item_id,
      sum(i.quantity * coalesce(oi.qty, oi.quantity::numeric, 0)) as expected_qty
    from public.order_items oi
    join public.menu_items mi on mi.id = oi.product_id
    join public.recipes r on r.menu_item_id = oi.product_id
    join public.recipe_ingredients i on i.recipe_id = r.id
    where oi.order_id = _order_id
      and oi.product_id is not null
      and oi.status <> 'void'
      and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
      and coalesce(mi.is_inventory_tracked, false) = true
    group by i.inventory_item_id
  loop
    select coalesce(abs(sum(im.quantity)), 0)
      into v_consumed
    from public.inventory_movements im
    where im.reference_id = _order_id
      and im.reference_type = 'order'
      and im.movement_type = 'sale'
      and im.item_id = v_ingredient.inventory_item_id;

    v_delta := greatest(v_ingredient.expected_qty - v_consumed, 0);

    if v_delta > 0 then
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
        v_ingredient.inventory_item_id,
        'sale',
        -v_delta,
        _order_id,
        'order',
        'Auto-consumo por venta'
      );
    end if;
  end loop;
end;
$$;

comment on function public.consume_inventory_from_order(uuid) is
  'Consume stock al venderse productos del menú con receta. Doble gate: '
  '(1) menu_items.is_inventory_tracked = true por producto, (2) '
  'business_settings.inventory_mode IN (''basic'',''advanced'') por negocio. '
  'En modo ''none'' el sistema no toca inventario. En ''basic'' las recetas '
  'son 1:1 auto-creadas (estilo Loyverse). En ''advanced'' el admin define '
  'recetas multi-ingrediente.';

commit;
