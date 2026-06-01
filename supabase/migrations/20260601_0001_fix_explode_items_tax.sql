-- =============================================================================
-- Fix (2026-06-01): fn_explode_items_to_units dejaba las unidades nuevas
-- SIN impuesto (tax_rate=0).
--
-- PROBLEMA:
--   Al dividir una cuenta, un item con qty>1 (ej. "2 Mojito Chinola") se
--   explota en N filas de qty=1. La unit 1 se UPDATE (conserva su tax_rate),
--   pero las units 2..N se INSERT SIN tax_rate / tax_mode / original_tax_rate
--   → caían a tax_rate=0 por el default de columna, y nunca se llamaba a
--   fn_populate_item_tax_lines. Resultado: el mismo producto, en la misma
--   orden, salía una vez gravado (28%) y otra en 0. Eso subdeclaraba ITBIS
--   y LEY en ventas dine_in que pasaron por "dividir cuenta".
--
-- Mismo bug y misma corrección que ya se aplicó a fn_split_items_equally en
-- 20260529_0002: copiar tax_rate/tax_mode/original_tax_rate del item origen
-- y refrescar las tax_lines de cada unidad (original + clones).
--
-- IDEMPOTENTE: sólo cambia la definición de la función. No toca filas
-- históricas (esas se corrigen aparte; ver nota al final).
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

    -- Refrescar tax_lines de la unit 1 tras bajar a qty=1 (el trigger ya
    -- recomputó subtotal/tax; esto sincroniza el breakdown).
    perform public.fn_populate_item_tax_lines(v_new_item_id);

    -- Unit 2..N → INSERT filas nuevas con qty=1 cada una. Mantienen
    -- check_id, status, notes, etc. del original Y SU IMPUESTO.
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
        tax_rate,             -- ← copiar del original (FIX)
        tax_mode,             -- ← copiar del original (FIX)
        original_tax_rate,    -- ← copiar del original (FIX)
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
        coalesce(v_item.tax_rate, 0),
        coalesce(v_item.tax_mode, 'exclusive'),
        v_item.original_tax_rate,
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

      -- Poblar tax_lines de la unit recién creada, basado en el subtotal
      -- que el trigger acaba de calcular. Sin esto el clon queda sin
      -- tax_lines y el breakdown se desincroniza (igual que el fix de
      -- fn_split_items_equally en 20260529_0002).
      perform public.fn_populate_item_tax_lines(v_new_item_id);

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
  'preservando check_id, status, notes Y el impuesto (tax_rate/tax_mode/'
  'original_tax_rate). Refresca tax_lines de cada unidad. Llamado al abrir '
  'el modal de dividir cuenta para que cada unidad sea transferible. '
  'Idempotente: items ya en qty=1 se ignoran. Pagados/anulados y qty '
  'fraccional se ignoran. Items con modificadores se ignoran.';

commit;

-- NOTA: filas históricas ya explotadas con tax_rate=0 (splits previos a este
-- fix) NO se corrigen aquí. Las que sigan en órdenes abiertas se sanan al
-- consolidar (fn_consolidate_keeper_atomic). Las ya facturadas quedan en sus
-- comprobantes emitidos — eso es corrección fiscal aparte (punto DGII).
