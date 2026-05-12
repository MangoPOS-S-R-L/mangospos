-- =============================================================================
-- Fase 0 del rediseno Toast: consolidar fracciones de qty pre-existentes.
--
-- Contexto (2026-05-11):
--   fn_split_items_equally(p_order_id, p_people) crea N filas en order_items
--   con qty = round(qty/people, 3). Para qty=3, people=3 → 1.0 cada una.
--   Para qty=2, people=3 → 0.667 cada una. La UI agrupada muestra "2 productos"
--   pero internamente hay 3 filas decimales. Cuando el cajero borra una fila,
--   queda 1.333 productos fantasma.
--
--   Esta migration *pre-Toast* normaliza la DB a qty entero antes de cambiar
--   la UI. Para cada orden abierta:
--     - Agrupa filas equivalentes (mismo producto en el mismo check, sin
--       modifiers, mismo unit_price/is_takeout/status/notes).
--     - Suma qty.
--     - Redondea al entero mas cercano.
--     - DELETE filas duplicadas, deja una sola con la suma.
--     - Recalcula totals.
--
--   Items con modifiers se saltan (sus qty fraccionales conviven con
--   modifier.qty fraccional; consolidar requiere recalcular ambos y se
--   pospone). Idem items ya 'paid'/'void' (cerrados, no se tocan).
--
-- Idempotente: correrla varias veces no rompe nada (si no hay fracciones,
-- el WHERE inicial devuelve 0 grupos).
-- =============================================================================

begin;

create or replace function public.fn_consolidate_order_to_integer(
  p_order_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group record;
  v_keeper_id uuid;
  v_keeper_qty numeric(10,3);
  v_target_qty integer;
  v_affected_checks uuid[] := array[]::uuid[];
  v_rows_consolidated integer := 0;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  -- Lock de la orden para evitar carrera con el cajero.
  perform 1 from public.orders where id = p_order_id for update;

  -- Loop por cada grupo consolidable. La identidad del grupo incluye TODOS
  -- los campos que diferencian un item visual del otro. Items con modifiers
  -- (subquery exists) se excluyen aqui.
  for v_group in
    select
      oi.order_id,
      coalesce(oi.check_id, '00000000-0000-0000-0000-000000000000'::uuid) as check_key,
      oi.check_id,
      oi.product_id,
      oi.product_name,
      oi.unit_price,
      oi.is_takeout,
      oi.status,
      coalesce(oi.notes, '') as notes_key,
      sum(oi.qty) as total_qty,
      sum(oi.discounts) as total_discounts,
      count(*) as row_count,
      min(oi.created_at) as earliest_created_at
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
      and not exists (
        select 1 from public.order_item_modifiers m where m.item_id = oi.id
      )
    group by
      oi.order_id,
      oi.check_id,
      oi.product_id,
      oi.product_name,
      oi.unit_price,
      oi.is_takeout,
      oi.status,
      coalesce(oi.notes, '')
    having count(*) > 1 or sum(oi.qty) <> round(sum(oi.qty))
  loop
    -- El keeper es la fila mas vieja del grupo (preserva created_at para
    -- el orden visual en el cart).
    select id, qty
      into v_keeper_id, v_keeper_qty
    from public.order_items
    where order_id = v_group.order_id
      and ((check_id is null and v_group.check_id is null)
           or check_id = v_group.check_id)
      and product_id is not distinct from v_group.product_id
      and product_name = v_group.product_name
      and unit_price = v_group.unit_price
      and is_takeout = v_group.is_takeout
      and status = v_group.status
      and coalesce(notes, '') = v_group.notes_key
      and not exists (
        select 1 from public.order_item_modifiers m where m.item_id = order_items.id
      )
    order by created_at asc, id asc
    limit 1;

    if v_keeper_id is null then
      continue;
    end if;

    -- Target entero. round() para 2.67 → 3; floor() seria mas conservador
    -- pero perderia inventario. Decision: round(); el cajero puede ajustar
    -- manualmente si era para menos.
    v_target_qty := greatest(round(v_group.total_qty)::integer, 1);

    update public.order_items
    set
      qty = v_target_qty,
      quantity = v_target_qty,
      discounts = round(coalesce(v_group.total_discounts, 0), 2)
    where id = v_keeper_id;

    -- Borrar los duplicados del grupo (todos los del grupo menos el keeper).
    delete from public.order_items oi
    where oi.order_id = v_group.order_id
      and oi.id <> v_keeper_id
      and ((oi.check_id is null and v_group.check_id is null)
           or oi.check_id = v_group.check_id)
      and oi.product_id is not distinct from v_group.product_id
      and oi.product_name = v_group.product_name
      and oi.unit_price = v_group.unit_price
      and oi.is_takeout = v_group.is_takeout
      and oi.status = v_group.status
      and coalesce(oi.notes, '') = v_group.notes_key
      and not exists (
        select 1 from public.order_item_modifiers m where m.item_id = oi.id
      );

    v_rows_consolidated := v_rows_consolidated + v_group.row_count::integer;

    if v_group.check_id is not null then
      v_affected_checks := array_append(v_affected_checks, v_group.check_id);
    end if;
  end loop;

  -- Recalcular totales para cada check afectado y la orden.
  if array_length(v_affected_checks, 1) > 0 then
    perform public.calculate_check_totals(c)
    from unnest(v_affected_checks) as c;
  end if;

  perform public.calculate_order_totals(p_order_id);

  return v_rows_consolidated;
end;
$$;

comment on function public.fn_consolidate_order_to_integer(uuid) is
  'Fase 0 Toast redesign: consolida filas duplicadas (mismo producto/check/notes/sin modifiers) '
  'y redondea qty a entero. Idempotente. Retorna el numero de filas duplicadas que se colapsaron. '
  'Se invoca: (a) one-shot al deploy via el SELECT al final de esta migration; '
  '(b) lazy al cargar una orden si el cliente detecta fracciones.';

grant execute on function public.fn_consolidate_order_to_integer(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- One-shot: consolidar todas las ordenes abiertas que tengan al menos una
-- fila con qty fraccional o duplicates sin modifiers.
-- ---------------------------------------------------------------------------

do $$
declare
  v_order record;
  v_total_rows integer := 0;
  v_orders_touched integer := 0;
  v_consolidated integer;
begin
  for v_order in
    select distinct o.id
    from public.orders o
    join public.order_items oi on oi.order_id = o.id
    where o.closed_at is null
      and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
      and not exists (
        select 1 from public.order_item_modifiers m where m.item_id = oi.id
      )
    group by o.id
    having
      bool_or(oi.qty <> round(oi.qty))
      or count(*) filter (
        where true
      ) > count(distinct (
        oi.check_id,
        oi.product_id,
        oi.product_name,
        oi.unit_price,
        oi.is_takeout,
        oi.status,
        coalesce(oi.notes, '')
      ))
  loop
    v_consolidated := public.fn_consolidate_order_to_integer(v_order.id);
    if v_consolidated > 0 then
      v_orders_touched := v_orders_touched + 1;
      v_total_rows := v_total_rows + v_consolidated;
    end if;
  end loop;

  raise notice 'Fase 0: % filas consolidadas en % ordenes abiertas',
    v_total_rows, v_orders_touched;
end$$;

commit;
