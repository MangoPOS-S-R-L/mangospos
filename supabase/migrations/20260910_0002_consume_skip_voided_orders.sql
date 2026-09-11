-- =============================================================================
-- 20260910_0002 — Una orden ANULADA no puede quedarse con el inventario.
--
-- EL BUG (detectado en The Pizza Hot, 2026-09-10):
--   `consume_inventory_from_order` filtra por `order_items.status <> 'void'`
--   pero NUNCA mira el estado de la ORDEN. Si la orden se anula sin marcar
--   uno por uno sus renglones como void —que es lo que hace
--   `fn_close_order_and_table(id, 'void')`, el camino normal de anulación—
--   el consumo ya escrito se queda ahí para siempre. Peor: cualquier toque
--   posterior a un renglón de esa orden dispara la reconciliación y vuelve a
--   descontar, porque para la función la orden sigue viva.
--
--   En Pizza Hot eso dejó movimientos de "Auto-consumo por venta" sobre
--   órdenes `canceled` de julio, algunos estampados 8 días después del
--   cierre.
--
-- EL ARREGLO, en dos piezas:
--   1. La función: si la orden está anulada, `expected` queda VACÍO. Como la
--      reconciliación siempre converge al delta, eso no significa "no hacer
--      nada" — significa DEVOLVER lo que se había consumido. Es la misma
--      maquinaria de siempre, solo que el objetivo pasa a ser cero.
--   2. Un trigger en `orders`: al anular, la devolución sale sola; si la
--      orden resucita (de void a cualquier otro estado), se vuelve a
--      descontar. La función es idempotente, así que el trigger puede
--      dispararse las veces que sea.
--
-- ANULADA = `status = 'canceled'` OR `status_ext = 'void'`. Se miran las dos
--   porque son columnas espejo que `fn_close_order_and_table` mantiene en
--   sincronía (ver 20260516_0017), pero que históricamente se
--   desincronizaron —esa misma migración trae un backfill para arreglarlo—.
--   Con una sola bastaría en teoría; con las dos no depende de la teoría.
--
-- BASE: reescrita sobre `20260907_0003_consume_modifier_ingredients.sql`,
--   que es la última versión del repo. Los ÚNICOS cambios son:
--     · nueva variable `v_order_voided`,
--     · el select inicial la llena,
--     · `expected_agg` gana `and not v_order_voided`.
--   Todo lo demás —recetas, link directo, combos, modificadores con signo,
--   resolución de bodega por área— queda intacto.
--
-- ⚠️  ANTES DE APLICAR, cotejar contra la definición VIVA:
--       select pg_get_functiondef(
--         'public.consume_inventory_from_order(uuid)'::regprocedure);
--     El 10-sep-2026 la viva medía 7172 caracteres y el CREATE de
--     20260907_0003 mide 7165 — la diferencia es el reformateo del header
--     que hace pg_get_functiondef, o sea que la viva ES esa. Si en tu base
--     el largo se aleja, la viva tiene algo que el repo no: tráelo acá
--     ANTES de aplicar o se pierde en silencio.
--
-- NO INCLUYE BACKFILL. Esta migración arregla de hoy en adelante. Devolver
--   el inventario que ya se quedó pegado en órdenes anuladas viejas se hace
--   por negocio y a ojo — ver `supabase/ARREGLAR_pizzahot_inventario.sql`.
--
-- IDEMPOTENTE: sí (create or replace + drop trigger if exists).
-- REVERSIBLE: sí (ver _ROLLBACK — restaura 20260907_0003 y borra el trigger).
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
  v_order_voided boolean;
begin
  -- El estado de la orden entra en la misma consulta que ya se hacía: una
  -- orden anulada tiene que llegar a expected = 0, no saltarse el trabajo.
  select
    ts.business_id,
    (o.status = 'canceled' or o.status_ext = 'void'::public.order_status)
    into v_business_id, v_order_voided
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
      --
      -- `not v_order_voided`: una orden anulada no espera NADA. Deja este
      -- lado del full outer join vacío, y el delta contra `already` sale
      -- negativo — o sea, devuelve el stock. No es un corte, es un objetivo.
      select
        inventory_item_id,
        warehouse_id,
        greatest(sum(q), 0) as expected
      from expected
      where inventory_item_id is not null
        and warehouse_id is not null
        and not v_order_voided
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

    v_note := case
                when v_pair.delta > 0 then 'Auto-consumo por venta'
                when v_order_voided   then 'Devolución por anulación de la orden'
                else 'Devolución por cancelación/edición'
              end;

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
  'directo, componentes de combo y modificadores con insumos propios. Una '
  'orden ANULADA (status canceled / status_ext void) espera cero: la misma '
  'reconciliación devuelve todo lo consumido. Idempotente: solo escribe la '
  'diferencia contra lo ya movido.';

-- ---------------------------------------------------------------------------
-- El disparador. Sin esto, anular una orden no devolvería nada hasta que
-- alguien tocara un renglón — que es justo lo que no pasa cuando se anula.
-- ---------------------------------------------------------------------------

create or replace function public.fn_orders_reconcile_inventory_on_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.consume_inventory_from_order(NEW.id);
  return NEW;
end;
$$;

comment on function public.fn_orders_reconcile_inventory_on_status() is
  'Trigger en orders: reconcilia inventario cuando la orden ENTRA o SALE del '
  'estado anulado. Al anular devuelve el stock consumido; si resucita, lo '
  'vuelve a descontar. Se apoya en la idempotencia de '
  'consume_inventory_from_order.';

drop trigger if exists trg_orders_reconcile_inventory_on_status on public.orders;

create trigger trg_orders_reconcile_inventory_on_status
  after update of status, status_ext on public.orders
  for each row
  when (
    (OLD.status is distinct from NEW.status
     or OLD.status_ext is distinct from NEW.status_ext)
    and (
      -- entra a anulada...
      NEW.status = 'canceled' or NEW.status_ext = 'void'::public.order_status
      -- ...o sale de anulada.
      or OLD.status = 'canceled' or OLD.status_ext = 'void'::public.order_status
    )
  )
  execute function public.fn_orders_reconcile_inventory_on_status();

comment on trigger trg_orders_reconcile_inventory_on_status on public.orders is
  'Devuelve el inventario al anular la orden y lo vuelve a descontar si la '
  'orden resucita. Ver 20260910_0002.';

commit;
