-- =============================================================================
-- Devolución automática de stock al cancelar/eliminar items.
--
-- PROBLEMA:
--   `consume_inventory_from_order` (mig. 20260516_0013) solo INSERTA
--   movements negativos cuando faltan por descontar. Si un item se anula
--   (status='void') o se elimina (DELETE) después de enviar a cocina, el
--   stock NO se devuelve — queda "perdido" en `inventory_stock`.
--
-- SOLUCIÓN:
--   1. Reescribir `consume_inventory_from_order` para que sea totalmente
--      reconciliadora: calcula `expected_qty` (de items vivos) y `net_consumed`
--      (suma de movimientos previos con signo), y emite UN movimiento que
--      cierra el delta — negativo si falta consumir, positivo si hay que
--      devolver. También itera sobre ingredientes con movimientos previos
--      aunque ya no haya items vivos (caso item eliminado completamente).
--   2. Triggers en `order_items` para llamar la reconciliación en cada
--      UPDATE de status/qty y en DELETE — así devolver es automático.
--
-- IDEMPOTENTE: CREATE OR REPLACE FUNCTION + DROP/CREATE TRIGGER.
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
  -- items vivos de la orden Y los que ya tienen movimientos persistidos
  -- para esta orden (capta items eliminados/anulados que necesitan devolver).
  for v_inventory_item_id in
    select inventory_item_id from (
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
      union
      select distinct im.item_id
      from public.inventory_movements im
      where im.reference_id = _order_id
        and im.reference_type = 'order'
        and im.movement_type = 'sale'
    ) u
    where u.inventory_item_id is not null
  loop
    -- Expected: cuánto debería consumir la orden ahora mismo de este
    -- ingrediente (sumando solo items vivos con tracking).
    select coalesce(
             sum(i.quantity * coalesce(oi.qty, oi.quantity::numeric, 0)),
             0
           )
      into v_expected
    from public.order_items oi
    join public.menu_items mi on mi.id = oi.product_id
    join public.recipes r on r.menu_item_id = oi.product_id
    join public.recipe_ingredients i on i.recipe_id = r.id
    where oi.order_id = _order_id
      and i.inventory_item_id = v_inventory_item_id
      and oi.status <> 'void'
      and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
      and coalesce(mi.is_inventory_tracked, false) = true;

    -- Net consumed: suma de movimientos sign-aware. Si solo hubo
    -- consumos: sum(neg) → negativo, así que -sum = positivo.
    -- Si hubo devoluciones previas: el signo se compensa.
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

    -- Movimiento que cierra el delta. Quantity tiene signo opuesto:
    --   delta > 0 (falta consumir) → quantity negativo (sale stock).
    --   delta < 0 (sobra consumido)  → quantity positivo (devuelve stock).
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
  'Reconcilia stock vs items vivos de la orden. Inserta movement con signo '
  'apropiado: negativo si falta descontar (venta nueva), positivo si sobra '
  '(item cancelado/eliminado). Idempotente — siempre converge al delta cero. '
  'Doble gate: menu_items.is_inventory_tracked + business_settings.inventory_mode.';

-- 3. Triggers en order_items: invocar la reconciliación cuando cambia
--    algo que afecta el consumo (status void/restore, qty/quantity, o
--    DELETE del item). Lo ponemos AFTER para que la fila final ya
--    refleje el estado correcto antes de calcular.

create or replace function public.fn_order_items_reconcile_inventory()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
begin
  if TG_OP = 'DELETE' then
    v_order_id := OLD.order_id;
  else
    v_order_id := NEW.order_id;
  end if;

  if v_order_id is not null then
    perform public.consume_inventory_from_order(v_order_id);
  end if;

  if TG_OP = 'DELETE' then
    return OLD;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_order_items_reconcile_inventory_iud
  on public.order_items;

-- AFTER UPDATE: solo cuando cambia un campo relevante para inventario.
-- AFTER DELETE: siempre.
create trigger trg_order_items_reconcile_inventory_upd
  after update of status, qty, quantity, product_id on public.order_items
  for each row
  when (
    OLD.status is distinct from NEW.status
    or OLD.qty is distinct from NEW.qty
    or OLD.quantity is distinct from NEW.quantity
    or OLD.product_id is distinct from NEW.product_id
  )
  execute function public.fn_order_items_reconcile_inventory();

create trigger trg_order_items_reconcile_inventory_del
  after delete on public.order_items
  for each row
  execute function public.fn_order_items_reconcile_inventory();

comment on function public.fn_order_items_reconcile_inventory() is
  'Trigger sobre order_items: invoca consume_inventory_from_order para que '
  'el stock se ajuste automáticamente cuando un item se anula (status=void), '
  'se cambia su cantidad, o se elimina. Sin este trigger, los items '
  'cancelados después de enviar a cocina no devolvían stock.';

commit;
