-- =============================================================================
-- F1 Almacenes por sección — el motor de consumo. Paso 2 de 2.
--
-- ⚠️  NO APLICAR SIN COTEJAR PRIMERO LA DEFINICIÓN VIVA.
--     La base de producción diverge del repositorio. Antes de aplicar esto
--     hay que correr:
--
--       select pg_get_functiondef(
--         'public.consume_inventory_from_order(uuid)'::regprocedure);
--
--     y comparar con `20260613_0001_finished_product_direct_inventory.sql`,
--     que es la última versión que tiene el repo y la base de esta. Si la
--     viva tiene algo que el repo no, hay que traerlo acá antes de aplicar
--     o se pierde en silencio.
--
-- QUÉ CAMBIA:
--   Hoy la función resuelve UNA bodega para toda la orden (la principal) y
--   reconcilia por insumo. Con almacenes por sección eso ya no alcanza: dos
--   platos de la misma orden pueden salir de bodegas distintas, y el mismo
--   insumo puede consumirse desde Cocina en un renglón y desde Bar en otro.
--
--   Esta versión reconcilia por PAR (insumo, bodega). La bodega de cada
--   renglón la decide `fn_resolve_consumption_warehouse` (20260901_0002),
--   que con la bandera apagada devuelve siempre la de siempre.
--
-- CON LA BANDERA APAGADA EL COMPORTAMIENTO ES IDÉNTICO AL ACTUAL:
--   el resolvedor devuelve null para todos los renglones, el coalesce cae en
--   la bodega por defecto, y todos los pares comparten esa única bodega —
--   o sea, exactamente la reconciliación por insumo de antes.
--
-- PROPIEDAD QUE VALE LA PENA CONOCER (se corrige sola):
--   Si una orden ya tenía consumo en la bodega principal y después se
--   prende la bandera, la reconciliación produce DOS movimientos: devuelve
--   lo consumido en la principal y lo descuenta de la bodega del área. El
--   consumo se MUDA en vez de duplicarse. Lo mismo si se le cambia el área
--   a un producto con órdenes abiertas.
--
-- REQUIERE: 20260901_0001 y 20260901_0002.
-- IDEMPOTENTE: sí (create or replace).
-- REVERSIBLE: sí (ver _ROLLBACK — restaura la versión de 20260613_0001).
-- =============================================================================

begin;

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
    ),
    expected_agg as (
      select inventory_item_id, warehouse_id, sum(q) as expected
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
  'bodega). La bodega de cada renglón la decide '
  'fn_resolve_consumption_warehouse: con la bandera '
  'warehouse_sections_enabled apagada, todos los pares caen en la bodega '
  'por defecto y el comportamiento es idéntico al histórico. Idempotente: '
  'solo escribe la diferencia contra lo ya movido. F1 Almacenes por sección.';

commit;
