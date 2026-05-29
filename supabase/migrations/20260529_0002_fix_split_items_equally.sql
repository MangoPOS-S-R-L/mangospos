-- =============================================================================
-- Fix sistémico de fn_split_items_equally — tres bugs latentes
-- =============================================================================
-- Bug 1 (principal — causa de tax_lines infladas, ITBIS reportado de más a
-- DGII, y total con centavos que no deberían existir): el INSERT de chunks
-- subsiguientes no copia `tax_rate`, `tax_mode`, `original_tax_rate` del
-- item original → caen al column default (`tax_rate=0`, `tax_mode='exclusive'`,
-- `original_tax_rate=null`). El trigger `fn_compute_item_totals` entonces
-- toma el branch exclusive con rate=0 y deja `subtotal=qty×unit_price` (gross
-- inflado, no la base extraída) y `tax=0`. Cuando luego algún proceso llama
-- `fn_populate_item_tax_lines`, escribe `tax_lines.amount = subtotal × rate/100`
-- usando el subtotal inflado → tax_lines infladas. Resultado: NCFs con ITBIS
-- de más, breakdown del display roto (subtotal+ITBIS+LEY ≠ Total), y centavos
-- que aparecen en el total porque hasOnlyInclusive cae a false.
--
-- Bug 2: tax_lines no se generan para los chunks (ni UPDATE ni INSERT) en
-- la función. Aunque exista un trigger AFTER INSERT que llame fn_populate,
-- las amounts quedan basadas en el subtotal del momento (inflado para los
-- clones rotos del Bug 1). Llamamos fn_populate explícitamente por cada
-- chunk para garantizar tax_lines correctos.
--
-- Bug 3: prorrateo de modifiers. Los modifier_qty representan cantidad
-- POR UNIDAD del item (el trigger fn_compute_item_totals hace
-- `line = item_qty × (unit + SUM(mod_qty × mod_price))`). La función estaba
-- prorrateando mod_qty por `chunk_qty/item_qty`, lo cual hace que la suma
-- post-split sea (1/N) del costo de modifier original. Ejemplo:
-- item qty=4 con modifier qty=1 price=10 → original total mods = 4×10 = 40.
-- Split en 4 chunks de qty=1 con prorrateo mod_qty=0.25 → suma = 4×0.25×10 = 10.
-- Pérdida de 30 por split. Fix: copiar mod_qty sin prorratear.
--
-- Safety net: al final del split, verificar que la suma de qty no cambió.
-- Si cambió por algún edge case no detectado, RAISE EXCEPTION para rollback
-- de la transacción completa. Mejor un error visible que corrupción silenciosa.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_split_items_equally(
  p_order_id uuid,
  p_people integer
)
RETURNS SETOF public.order_checks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
  -- Safety net
  v_total_qty_after numeric(10,3);
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
    -- por chunk (copiados, no prorrateados — ver Bug 3 del header).
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
        -- Primer chunk: UPDATE el item original (preserva su tax_rate,
        -- tax_mode, original_tax_rate, etc.). Trigger fn_compute_item_totals
        -- recompute subtotal/tax/total con la qty nueva.
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
        -- Chunk subsiguiente: INSERT fila nueva COPIANDO los atributos
        -- de impuestos del item original. Sin esto, la fila clonada cae
        -- a tax_rate=0 / tax_mode='exclusive' por column default (Bug 1).
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
          tax_rate,             -- ← copiar del original
          tax_mode,             -- ← copiar del original
          original_tax_rate,    -- ← copiar del original
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
          coalesce(v_item.tax_rate, 0),
          coalesce(v_item.tax_mode, 'exclusive'),
          v_item.original_tax_rate,
          coalesce(v_item.created_at, now())
        )
        returning id into v_new_item_id;
      end if;

      -- Modifiers: copiar (NO prorratear). mod_qty representa cantidad por
      -- unidad de item, no total. El trigger calcula
      -- line = item_qty × (unit + SUM(mod_qty × mod_price)) — prorratear
      -- mod_qty por chunk hace que la suma post-split sea 1/N del costo
      -- original (Bug 3). Copiar tal cual mantiene el costo exacto.
      for v_mod in select value from jsonb_array_elements(v_modifiers)
      loop
        v_mod_qty := coalesce((v_mod->>'qty')::numeric, 1);
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

      -- Refrescar tax_lines del chunk recién creado/actualizado, basado
      -- en el subtotal que el trigger acaba de calcular para esta qty.
      -- Sin esto, los clones quedan sin tax_lines (o con tax_lines viejas
      -- del estado pre-split) y el display de breakdown se desincroniza
      -- (Bug 2).
      perform public.fn_populate_item_tax_lines(v_new_item_id);

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

  -- Safety net: verificar que la qty total se preservó. Si por algún edge
  -- case no detectado se perdieron unidades, abortamos toda la transacción
  -- en vez de dejar la orden corrupta. Mejor un error visible al cajero
  -- que productos desaparecidos silenciosamente.
  select coalesce(sum(oi.qty), 0)
    into v_total_qty_after
  from public.order_items oi
  where oi.order_id = p_order_id
    and oi.status not in ('paid'::public.item_status,
                          'void'::public.item_status);

  if v_total_qty_after::integer <> v_total_open_qty::integer then
    raise exception
      'SPLIT_QTY_MISMATCH: la cantidad total cambió de % a % durante el split. '
      'Operación abortada para preservar la data. Contacta soporte.',
      v_total_open_qty::integer, v_total_qty_after::integer
      using errcode = 'P0001';
  end if;

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
$function$;
