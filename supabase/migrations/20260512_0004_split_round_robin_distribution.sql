-- =============================================================================
-- Fix de distribución en fn_split_items_equally.
--
-- Bug reportado (2026-05-12):
--   Usuario reporta: con 2 productos y 2 personas, "Dividir en partes
--   iguales" pone los 2 productos en C2 en vez de 1 en C2 y 1 en C3.
--
--   Causa: en la migration 20260512_0003 mi lógica para items no
--   divisibles per-item (ej. qty=1 con people=2 → 1%2=1) los asignaba
--   TODOS al primer check (v_target_check_ids[1]) en vez de balancear
--   entre los checks disponibles. Con 2 items qty=1 ambos van a C2.
--
-- Fix:
--   Algoritmo de distribución round-robin con target uniforme:
--
--     1. target_per_check = total_units / people
--     2. Mantener contador v_qty_in_current = unidades ya asignadas al
--        check actual (v_idx).
--     3. Para cada item: rellenar el check actual hasta llegar al
--        target. Si el item tiene más unidades, partirlo en la frontera
--        y crear una nueva fila en el siguiente check.
--     4. Cuando el check actual llega a target, avanzar al siguiente.
--
--   Casos cubiertos:
--     - 2 items qty=1 entre 2 personas: target=1. Item1→C2(1). C2 lleno,
--       v_idx avanza. Item2→C3(1). C3 lleno. ✓
--     - 4 items qty=1 entre 2 personas: target=2. Item1+2→C2(2). v_idx
--       avanza. Item3+4→C3(2). ✓
--     - 1 item qty=2 entre 2 personas: target=1. Item1 se parte:
--       qty=1 a C2 (UPDATE original), qty=1 a C3 (INSERT nuevo). ✓
--     - 3 mojis qty=1 + 3 cervezas qty=1 entre 3 personas: target=2.
--       Moji1→C2(1), Moji2→C2(2). v_idx avanza. Moji3→C3(1), Cerveza1→
--       C3(2). v_idx avanza. Cerveza2→C4(1), Cerveza3→C4(2). ✓
--
--   Discounts se prorratean proporcionalmente a la qty asignada por
--   chunk. Modifiers también.
--
-- Pre-condiciones (de la migration 0003 que dejamos vigente):
--   - No hay items con qty fraccional (FRACTIONAL_QTY_NOT_ALLOWED).
--   - total_units >= people (NOT_ENOUGH_UNITS).
--   - total_units % people = 0 (NON_DIVISIBLE_QTY).
-- =============================================================================

begin;

create or replace function public.fn_split_items_equally(
  p_order_id uuid,
  p_people integer
)
returns setof public.order_checks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_people integer := coalesce(p_people, 0);
  v_idx integer;
  v_pos integer;
  v_item record;
  v_target_check_ids uuid[] := array[]::uuid[];
  v_item_qty integer;
  v_item_discounts numeric(12,2);
  v_new_item_id uuid;
  v_modifiers jsonb;
  v_mod jsonb;
  v_mod_qty numeric(10,3);
  v_total_open_qty numeric(10,3);
  v_has_fractional boolean := false;
  -- Cursor de distribución
  v_target_per_check integer;
  v_current_idx integer := 1;
  v_qty_in_current integer := 0;
  v_chunk_qty integer;
  v_chunk_discount numeric(12,2);
  v_remaining_qty integer;
  v_remaining_discount numeric(12,2);
  v_first_chunk boolean;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  if v_people < 2 or v_people > 4 then
    raise exception 'PEOPLE_OUT_OF_RANGE';
  end if;

  if not exists (select 1 from public.orders o where o.id = p_order_id) then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  -- Validación 1: ningún item abierto puede tener qty fraccional.
  select bool_or(oi.qty <> round(oi.qty)), coalesce(sum(oi.qty), 0)
    into v_has_fractional, v_total_open_qty
  from public.order_items oi
  where oi.order_id = p_order_id
    and oi.status not in ('paid'::public.item_status,
                          'void'::public.item_status);

  if coalesce(v_has_fractional, false) then
    raise exception
      'FRACTIONAL_QTY_NOT_ALLOWED: la orden tiene items con qty fraccional. '
      'Ejecuta fn_consolidate_order_to_integer(%) primero o normaliza '
      'manualmente.', p_order_id
      using errcode = 'check_violation';
  end if;

  -- Validación 2: total debe alcanzar para todas las cuentas.
  if v_total_open_qty::integer < v_people then
    raise exception
      'NOT_ENOUGH_UNITS: hay % producto(s) y se piden % cuentas. '
      'Reduce el número de personas o agrega más productos.',
      v_total_open_qty::integer, v_people
      using errcode = 'check_violation';
  end if;

  -- Validación 3: total debe dividirse exactamente.
  if (v_total_open_qty::integer) % v_people <> 0 then
    raise exception
      'NON_DIVISIBLE_QTY: % producto(s) no se reparten de forma exacta '
      'entre % cuentas. Usa drag & drop para asignación manual o cambia '
      'el número de personas.',
      v_total_open_qty::integer, v_people
      using errcode = 'check_violation';
  end if;

  -- Crear/asegurar checks objetivo C2..C(N+1).
  for v_idx in 1..v_people loop
    v_pos := v_idx + 1;
    v_target_check_ids := array_append(
      v_target_check_ids,
      public.fn_get_or_create_check(p_order_id, v_pos)
    );
  end loop;

  update public.order_checks oc
  set is_closed = false,
      closed_at = null
  where oc.id = any(v_target_check_ids);

  v_target_per_check := (v_total_open_qty::integer) / v_people;

  -- Distribución round-robin: rellenar cada check hasta target, avanzar
  -- al siguiente cuando se llena. Items se parten en chunks enteros
  -- cuando cruzan la frontera de un check.
  for v_item in
    select oi.*
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.status not in ('paid'::public.item_status,
                            'void'::public.item_status)
    order by oi.created_at, oi.id
  loop
    v_item_qty := round(greatest(coalesce(v_item.qty, v_item.quantity, 1), 0))::integer;
    if v_item_qty <= 0 then
      continue;
    end if;

    v_item_discounts := coalesce(v_item.discounts, 0);
    v_remaining_qty := v_item_qty;
    v_remaining_discount := v_item_discounts;
    v_first_chunk := true;

    -- Cargar modifiers una sola vez para este item.
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'name', m.name,
          'qty', m.qty,
          'price', m.price
        )
      ),
      '[]'::jsonb
    )
    into v_modifiers
    from public.order_item_modifiers m
    where m.item_id = v_item.id;

    -- Los modifiers del item original se borran y se re-insertan
    -- prorrateados por chunk (lo mismo que hace el código legacy).
    if jsonb_array_length(coalesce(v_modifiers, '[]'::jsonb)) > 0 then
      delete from public.order_item_modifiers where item_id = v_item.id;
    end if;

    while v_remaining_qty > 0 and v_current_idx <= v_people loop
      -- Capacidad disponible en el check actual.
      v_chunk_qty := least(
        v_remaining_qty,
        v_target_per_check - v_qty_in_current
      );

      if v_chunk_qty <= 0 then
        -- Check actual ya está lleno, avanzar.
        v_current_idx := v_current_idx + 1;
        v_qty_in_current := 0;
        continue;
      end if;

      -- Prorratear discount con la proporción del chunk al item original.
      if v_item_qty > 0 then
        v_chunk_discount := round(
          v_item_discounts * (v_chunk_qty::numeric / v_item_qty::numeric),
          2
        );
      else
        v_chunk_discount := 0;
      end if;

      -- Último chunk del item: absorbe el residuo del discount para que
      -- la suma cuadre exactamente.
      if v_chunk_qty = v_remaining_qty then
        v_chunk_discount := round(v_remaining_discount, 2);
      end if;
      v_chunk_discount := greatest(v_chunk_discount, 0);

      if v_first_chunk then
        -- Primer chunk: UPDATE el item original.
        update public.order_items oi
        set
          check_id = v_target_check_ids[v_current_idx],
          qty = v_chunk_qty,
          quantity = v_chunk_qty,
          discounts = v_chunk_discount
        where oi.id = v_item.id;

        v_new_item_id := v_item.id;
        v_first_chunk := false;
      else
        -- Chunk subsiguiente: INSERT fila nueva en el siguiente check.
        insert into public.order_items (
          order_id,
          product_id,
          product_name,
          sku,
          check_id,
          quantity,
          qty,
          unit_price,
          is_takeout,
          status,
          notes,
          discounts,
          created_at
        ) values (
          v_item.order_id,
          v_item.product_id,
          v_item.product_name,
          v_item.sku,
          v_target_check_ids[v_current_idx],
          v_chunk_qty,
          v_chunk_qty,
          v_item.unit_price,
          coalesce(v_item.is_takeout, false),
          v_item.status,
          v_item.notes,
          v_chunk_discount,
          coalesce(v_item.created_at, now())
        )
        returning id into v_new_item_id;
      end if;

      -- Prorratear modifiers para este chunk.
      for v_mod in select value from jsonb_array_elements(v_modifiers)
      loop
        v_mod_qty := round(
          coalesce((v_mod->>'qty')::numeric, 1) *
          case when v_item_qty = 0 then 0 else (v_chunk_qty::numeric / v_item_qty::numeric) end,
          3
        );
        if v_mod_qty > 0 then
          insert into public.order_item_modifiers(item_id, name, qty, price)
          values (
            v_new_item_id,
            coalesce(v_mod->>'name', ''),
            v_mod_qty,
            coalesce((v_mod->>'price')::numeric, 0)
          );
        end if;
      end loop;

      -- Avanzar cursores.
      v_qty_in_current := v_qty_in_current + v_chunk_qty;
      v_remaining_qty := v_remaining_qty - v_chunk_qty;
      v_remaining_discount := v_remaining_discount - v_chunk_discount;

      -- Si el check actual alcanzó target, avanzar al siguiente.
      if v_qty_in_current >= v_target_per_check then
        v_current_idx := v_current_idx + 1;
        v_qty_in_current := 0;
      end if;
    end loop;
  end loop;

  -- Cerrar checks vacíos extra (positions > v_people+1).
  update public.order_checks oc
  set is_closed = true,
      closed_at = now()
  where oc.order_id = p_order_id
    and oc.position > (v_people + 1)
    and oc.position > 1
    and not exists (
      select 1
      from public.order_items oi
      where oi.check_id = oc.id
        and oi.status not in ('paid'::public.item_status,
                              'void'::public.item_status)
    );

  return query
  select *
  from public.order_checks oc
  where oc.order_id = p_order_id
    and oc.position between 2 and (v_people + 1)
  order by oc.position;
end;
$$;

grant execute on function public.fn_split_items_equally(uuid, integer)
  to authenticated;

commit;
