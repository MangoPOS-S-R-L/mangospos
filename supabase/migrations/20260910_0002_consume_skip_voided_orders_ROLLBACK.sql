-- =============================================================================
-- ROLLBACK de 20260910_0002_consume_skip_voided_orders.sql
--
-- Devuelve `consume_inventory_from_order` a la versión de
-- 20260907_0003 (sin el guard de orden anulada) y borra el trigger de
-- `orders`.
--
-- ⚠️  OJO: revertir NO deshace los movimientos que el arreglo ya generó. Si
--     alguna orden se anuló con la migración puesta, su devolución de stock
--     queda escrita — y está bien que quede: es inventario que sí volvió al
--     almacén. Lo que se pierde al revertir es que las PRÓXIMAS anulaciones
--     vuelvan a dejar el consumo pegado.
-- =============================================================================

begin;

drop trigger if exists trg_orders_reconcile_inventory_on_status on public.orders;
drop function if exists public.fn_orders_reconcile_inventory_on_status();

create or replace function public.consume_inventory_from_order(_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_default_warehouse_id uuid;
  v_business_id uuid;
  v_mode text;
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

  -- La bodega de siempre: sigue siendo el destino cuando el producto no
  -- tiene área, cuando el área no tiene almacén, o cuando la bandera de
  -- secciones está apagada.
  select w.id
    into v_default_warehouse_id
  from public.warehouses w
  where w.business_id = v_business_id
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_default_warehouse_id is null then
    return;
  end if;

  for v_pair in
    with expected as (
      -- (1) Productos normales con receta (NO combos).
      select
        i.inventory_item_id,
        coalesce(
          public.fn_resolve_consumption_warehouse(
            v_business_id, oi.product_id, null),
          v_default_warehouse_id
        ) as warehouse_id,
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
        coalesce(
          public.fn_resolve_consumption_warehouse(
            v_business_id, oi.product_id, null),
          v_default_warehouse_id
        ),
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

      -- (2) Componentes de combo. El área la manda el COMPONENTE —es lo que
      -- se prepara—; si el componente no tiene área, se prueba con la del
      -- combo antes de caer en la bodega por defecto.
      select
        i.inventory_item_id,
        coalesce(
          public.fn_resolve_consumption_warehouse(
            v_business_id, oim.menu_item_id, null),
          public.fn_resolve_consumption_warehouse(
            v_business_id, oi.product_id, null),
          v_default_warehouse_id
        ),
        i.quantity
          * coalesce(oim.qty, 1)
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

      union all

      -- (3) MODIFICADORES con insumos propios (20260907_0001). Cantidad CON
      -- SIGNO: «Queso extra» suma, «Sin queso» resta lo que la receta base
      -- del producto iba a descontar. La bodega la manda el producto padre.
      select
        ming.inventory_item_id,
        coalesce(
          public.fn_resolve_consumption_warehouse(
            v_business_id, oi.product_id, null),
          v_default_warehouse_id
        ),
        ming.quantity
          * coalesce(oim.qty, 1)
          * coalesce(oi.qty, oi.quantity::numeric, 0)
      from public.order_items oi
      join public.order_item_modifiers oim
        on oim.item_id = oi.id and oim.modifier_id is not null
      join public.modifier_ingredients ming
        on ming.modifier_id = oim.modifier_id
      where oi.order_id = _order_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and ming.inventory_item_id is not null
    ),
    expected_agg as (
      -- greatest(..., 0): una línea de modificador negativa puede ANULAR el
      -- consumo de la receta base, pero jamás darlo vuelta y crear stock.
      select
        inventory_item_id,
        warehouse_id,
        greatest(sum(q), 0) as expected
      from expected
      where inventory_item_id is not null
        and warehouse_id is not null
      group by inventory_item_id, warehouse_id
    ),
    -- Lo ya movido por ESTA orden, por par. Es lo que hace idempotente a la
    -- función: se la puede llamar mil veces y solo escribe la diferencia.
    already as (
      select
        im.item_id            as inventory_item_id,
        im.warehouse_id,
        coalesce(-sum(im.quantity), 0) as consumed
      from public.inventory_movements im
      where im.reference_id = _order_id
        and im.reference_type = 'order'
        and im.movement_type = 'sale'
      group by im.item_id, im.warehouse_id
    )
    select
      coalesce(e.inventory_item_id, a.inventory_item_id) as item_id,
      coalesce(e.warehouse_id, a.warehouse_id)           as warehouse_id,
      coalesce(e.expected, 0) - coalesce(a.consumed, 0)  as delta
    from expected_agg e
    full outer join already a
      on a.inventory_item_id = e.inventory_item_id
     and a.warehouse_id      = e.warehouse_id
  loop
    if v_pair.delta = 0
       or v_pair.item_id is null
       or v_pair.warehouse_id is null then
      continue;
    end if;

    v_note := case when v_pair.delta > 0 then 'Auto-consumo por venta'
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
      v_pair.warehouse_id,
      v_pair.item_id,
      'sale',
      -v_pair.delta,
      _order_id,
      'order',
      v_note
    );
  end loop;
end;
$function$;

comment on function public.consume_inventory_from_order(uuid) is
  'Reconcilia el consumo de inventario de una orden por par (insumo, '
  'bodega). Expande: recetas de producto, productos terminados con link '
  'directo, componentes de combo y MODIFICADORES con insumos propios '
  '(modifier_ingredients, con cantidad firmada para el «sin queso» y el '
  'cambio de pan). El esperado por par se recorta a 0: un negativo mal '
  'configurado deja de descontar, nunca crea stock. Idempotente: solo '
  'escribe la diferencia contra lo ya movido.';

commit;
