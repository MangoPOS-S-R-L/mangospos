-- =============================================================================
-- Split bill UX (2026-05-13): cada unidad debe ser transferible
-- independientemente.
--
-- PROBLEMA:
--   "2 Coca Cola" aparece como 1 fila con qty=2 en el modal de dividir
--   cuenta. Si el cliente A quiere una y el cliente B la otra, el cajero
--   no puede mover sólo una — el item entero va junto.
--
-- SOLUCIÓN:
--   `fn_explode_items_to_units(p_order_id)` divide cada item abierto
--   con qty > 1 en N filas de qty=1. Se llama desde el cliente al abrir
--   el modal de dividir cuenta. Al guardar/cerrar, las filas que
--   terminaron en la misma sub-cuenta se vuelven a consolidar
--   (consolidateCheckItems ya existente, lado Dart).
--
-- INVARIANTES PRESERVADOS:
--   - El item original mantiene su ID (UPDATE qty=1) → no rompemos FKs
--     ni referencias en print_jobs, etc.
--   - Items qty fraccional (legacy) NO se tocan — el RPC asume enteros.
--   - Items con status='paid' o 'void' NO se tocan (ya cobrados).
--   - Items CON modificadores NO se tocan. Razón: consolidateCheckItems
--     (Dart) deliberadamente no fusiona items con mods para no mezclar
--     recetas distintas. Si los explotaramos y el cajero cancela el
--     modal, la consolidación de cierre no los volvería a fusionar y
--     romperíamos el invariante "misma receta = una fila".
--     Trade-off aceptado: "2 Burgers con extra queso" se mantiene como
--     1 fila y no se puede transferir una unidad — mismo comportamiento
--     que antes del fix, no es regresión.
--   - Discount se prorratea proporcionalmente; el último child absorbe
--     el residuo para que la suma cuadre exactamente.
--
-- IDEMPOTENTE:
--   Llamar dos veces consecutivas es no-op la segunda vez (todos los
--   items ya están en qty=1).
-- =============================================================================

begin;

create or replace function public.fn_explode_items_to_units(
  p_order_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item record;
  v_idx integer;
  v_modifiers jsonb;
  v_mod jsonb;
  v_total_qty integer;
  v_total_discount numeric(12,2);
  v_base_discount numeric(12,2);
  v_unit_discount numeric(12,2);
  v_discount_remaining numeric(12,2);
  v_mod_qty_per_unit numeric(10,3);
  v_new_item_id uuid;
  v_exploded_count integer := 0;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  if not exists (select 1 from public.orders o where o.id = p_order_id) then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  for v_item in
    select oi.*
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.status not in ('paid'::public.item_status,
                            'void'::public.item_status)
      and coalesce(oi.qty, oi.quantity, 1) > 1
      -- Sólo items con qty entera. Los fraccionales (legacy) se ignoran
      -- a propósito; fn_consolidate_order_to_integer existe para
      -- normalizarlos primero si el cajero lo pide explícitamente.
      and coalesce(oi.qty, oi.quantity, 1) =
          round(coalesce(oi.qty, oi.quantity, 1))
      -- Items CON modificadores NO se explotan. consolidateCheckItems
      -- (Dart) no fusiona items con mods (para no mezclar recetas),
      -- así que si el cajero cancela el modal sin aplicar, las filas
      -- exploded se quedarían separadas para siempre. Mantenerlos como
      -- 1 fila preserva el invariante "misma receta = una fila".
      and not exists (
        select 1
        from public.order_item_modifiers m
        where m.item_id = oi.id
      )
    order by oi.created_at, oi.id
  loop
    v_total_qty := round(
      greatest(coalesce(v_item.qty, v_item.quantity, 1), 0)
    )::integer;
    if v_total_qty <= 1 then
      continue;
    end if;

    v_total_discount := coalesce(v_item.discounts, 0);
    v_base_discount := round(v_total_discount / v_total_qty, 2);
    v_discount_remaining := v_total_discount;

    -- Capturar modifiers del original una sola vez.
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

    -- Borrar mods del original para re-insertarlos prorrateados por
    -- unit. Igual estrategia que fn_split_items_equally.
    if jsonb_array_length(coalesce(v_modifiers, '[]'::jsonb)) > 0 then
      delete from public.order_item_modifiers where item_id = v_item.id;
    end if;

    -- Unit 1 → UPDATE el row original. Mantiene su id para no romper
    -- referencias externas (print_jobs, etc).
    update public.order_items oi
    set qty = 1,
        quantity = 1,
        discounts = v_base_discount
    where oi.id = v_item.id;

    v_new_item_id := v_item.id;
    v_discount_remaining := v_discount_remaining - v_base_discount;

    -- Re-insertar mods prorrateados para esta primera unit.
    for v_mod in select value from jsonb_array_elements(v_modifiers)
    loop
      v_mod_qty_per_unit := round(
        coalesce((v_mod->>'qty')::numeric, 1) / v_total_qty::numeric,
        3
      );
      if v_mod_qty_per_unit > 0 then
        insert into public.order_item_modifiers(item_id, name, qty, price)
        values (
          v_new_item_id,
          coalesce(v_mod->>'name', ''),
          v_mod_qty_per_unit,
          coalesce((v_mod->>'price')::numeric, 0)
        );
      end if;
    end loop;

    -- Unit 2..N → INSERT filas nuevas con qty=1 cada una. Mantienen
    -- check_id, status, notes, etc. del original.
    for v_idx in 2..v_total_qty loop
      if v_idx = v_total_qty then
        -- Última unit absorbe el residuo del discount para que la
        -- suma cuadre exactamente con el total original.
        v_unit_discount := greatest(v_discount_remaining, 0);
      else
        v_unit_discount := v_base_discount;
      end if;

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
        v_item.check_id,
        1,
        1,
        v_item.unit_price,
        coalesce(v_item.is_takeout, false),
        v_item.status,
        v_item.notes,
        v_unit_discount,
        coalesce(v_item.created_at, now())
      )
      returning id into v_new_item_id;

      v_discount_remaining := v_discount_remaining - v_unit_discount;

      -- Clonar mods prorrateados a esta unit.
      for v_mod in select value from jsonb_array_elements(v_modifiers)
      loop
        v_mod_qty_per_unit := round(
          coalesce((v_mod->>'qty')::numeric, 1) / v_total_qty::numeric,
          3
        );
        if v_mod_qty_per_unit > 0 then
          insert into public.order_item_modifiers(item_id, name, qty, price)
          values (
            v_new_item_id,
            coalesce(v_mod->>'name', ''),
            v_mod_qty_per_unit,
            coalesce((v_mod->>'price')::numeric, 0)
          );
        end if;
      end loop;

      v_exploded_count := v_exploded_count + 1;
    end loop;
  end loop;

  return v_exploded_count;
end;
$$;

grant execute on function public.fn_explode_items_to_units(uuid)
  to authenticated, service_role;

comment on function public.fn_explode_items_to_units(uuid) is
  'Divide cada order_item abierto con qty>1 en N filas de qty=1, '
  'preservando check_id, status y notes. Llamado al abrir el modal de '
  'dividir cuenta para que cada unidad sea transferible independientemente. '
  'Al cerrar/guardar el modal, las filas que terminaron en la misma '
  'sub-cuenta se vuelven a consolidar (consolidateCheckItems lado Dart). '
  'Idempotente: items ya en qty=1 se ignoran. Items pagados/anulados se '
  'ignoran. Items con qty fraccional (legacy) se ignoran a propósito. '
  'Items CON modificadores se ignoran porque consolidateCheckItems no '
  'fusiona items con mods (preserva recetas distintas).';

commit;
