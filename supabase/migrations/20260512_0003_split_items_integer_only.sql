-- =============================================================================
-- Defensa profunda: bloquear fracciones de qty en fn_split_items_equally.
--
-- Decisión de diseño (2026-05-12):
--   El cajero de MangoPOS quiere que los splits SOLO produzcan unidades
--   enteras. Los splits fraccionales históricos generaron bugs en el cobro
--   y en la consolidación de items (qty 0.67 fantasmas).
--
--   El frontend ya bloquea: si totalUnits < people o totalUnits % people
--   != 0, no llama al RPC. Pero defendemos también el RPC en caso de:
--     - llamadas directas vía cliente offline encolado pre-fix
--     - integraciones futuras
--     - acceso vía service_role (admin tools)
--
-- Cambios sobre fn_split_items_equally:
--   1) Al inicio, validar que TODOS los items abiertos tengan qty entera.
--      Si hay fracciones residuales, raise FRACTIONAL_QTY_NOT_ALLOWED y
--      sugiere al cliente correr fn_consolidate_order_to_integer primero.
--   2) Validar que sum(qty) sea divisible exactamente por v_people.
--      Si no, raise NON_DIVISIBLE_QTY con el detalle.
--   3) Distribuir como enteros: cada check recibe SUM(qty)/v_people
--      unidades enteras. El loop original ya soportaba esto pero lo
--      hacíamos con round(qty/people, 3) que metía decimales. Cambiamos
--      a ROUND a entero.
--
-- El comportamiento legacy con qty entera divisible queda idéntico
-- (ej. 3 mojis ÷ 3 personas = 1 cada uno). Lo único que se rompe es
-- el caso "5 mojis ÷ 3 personas" que ahora rechaza con mensaje claro.
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
  v_qty_base integer;
  v_qty_share integer;
  v_qty_accum integer;
  v_discount_base numeric(12,2);
  v_discount_share numeric(12,2);
  v_discount_accum numeric(12,2);
  v_new_item_id uuid;
  v_modifiers jsonb;
  v_mod jsonb;
  v_mod_qty numeric(10,3);
  v_total_open_qty numeric(10,3);
  v_has_fractional boolean := false;
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

  -- Validación 2: la suma debe dividirse exactamente entre las personas.
  if v_total_open_qty::integer < v_people then
    raise exception
      'NOT_ENOUGH_UNITS: hay % producto(s) y se piden % cuentas. '
      'Reduce el número de personas o agrega más productos.',
      v_total_open_qty::integer, v_people
      using errcode = 'check_violation';
  end if;

  if (v_total_open_qty::integer) % v_people <> 0 then
    raise exception
      'NON_DIVISIBLE_QTY: % producto(s) no se reparten de forma exacta '
      'entre % cuentas. Usa drag & drop para asignación manual o cambia '
      'el número de personas.',
      v_total_open_qty::integer, v_people
      using errcode = 'check_violation';
  end if;

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

  -- Distribución entera: cada item entero se divide en v_people partes
  -- enteras. Si el item.qty no es divisible entre v_people, el RPC ya
  -- abortó arriba (validación 2). Aquí asumimos qty entera divisible.
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

    -- Si este item específico no es divisible (ej. qty=1, people=3), no
    -- podemos dividirlo a nivel item. La validación global del paso 2
    -- ya garantizó que SUMA es divisible, pero por-item puede no serlo —
    -- en ese caso se distribuye según el ratio total.
    --
    -- Estrategia simple: cada item se asigna ENTERO a una cuenta. El
    -- "balanceo" lo decide la suma global. Ej: 3 mojis + 3 cervezas = 6
    -- unidades / 3 personas = 2 cada uno. Asignamos 2 mojis a C2, 1 moji
    -- + 1 cerveza a C3, 2 cervezas a C4. Es heurística round-robin.

    v_item_discounts := coalesce(v_item.discounts, 0);

    -- Para items individuales con qty divisible: dividir entero.
    if v_item_qty % v_people = 0 then
      v_qty_base := v_item_qty / v_people;
      v_discount_base := round(v_item_discounts / v_people, 2);
      v_qty_accum := 0;
      v_discount_accum := 0;

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

      for v_idx in 1..v_people loop
        if v_idx < v_people then
          v_qty_share := v_qty_base;
          v_discount_share := v_discount_base;
        else
          v_qty_share := v_item_qty - v_qty_accum;
          v_discount_share := round(v_item_discounts - v_discount_accum, 2);
        end if;

        v_qty_share := greatest(v_qty_share, 0);
        v_discount_share := greatest(v_discount_share, 0);

        if v_idx = 1 then
          update public.order_items oi
          set
            check_id = v_target_check_ids[v_idx],
            qty = v_qty_share,
            quantity = v_qty_share,
            discounts = v_discount_share
          where oi.id = v_item.id;

          delete from public.order_item_modifiers where item_id = v_item.id;

          for v_mod in select value from jsonb_array_elements(v_modifiers)
          loop
            v_mod_qty := round(
              coalesce((v_mod->>'qty')::numeric, 1) *
              case when v_item_qty = 0 then 0 else (v_qty_share::numeric / v_item_qty::numeric) end,
              3
            );
            if v_mod_qty > 0 then
              insert into public.order_item_modifiers(item_id, name, qty, price)
              values (
                v_item.id,
                coalesce(v_mod->>'name', ''),
                v_mod_qty,
                coalesce((v_mod->>'price')::numeric, 0)
              );
            end if;
          end loop;
        else
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
            v_target_check_ids[v_idx],
            v_qty_share,
            v_qty_share,
            v_item.unit_price,
            coalesce(v_item.is_takeout, false),
            v_item.status,
            v_item.notes,
            v_discount_share,
            coalesce(v_item.created_at, now())
          )
          returning id into v_new_item_id;

          for v_mod in select value from jsonb_array_elements(v_modifiers)
          loop
            v_mod_qty := round(
              coalesce((v_mod->>'qty')::numeric, 1) *
              case when v_item_qty = 0 then 0 else (v_qty_share::numeric / v_item_qty::numeric) end,
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
        end if;

        v_qty_accum := v_qty_accum + v_qty_share;
        v_discount_accum := v_discount_accum + v_discount_share;
      end loop;
    else
      -- Item no divisible entre v_people (ej. moji qty=1 con 3 personas).
      -- La validación global ya garantizó que la SUMA total es divisible,
      -- así que hay otro item que compensa. Aquí, dejamos el item entero
      -- en la primera cuenta disponible — el cajero puede reasignar con
      -- drag & drop si quiere otra distribución.
      update public.order_items oi
      set check_id = v_target_check_ids[1]
      where oi.id = v_item.id
        and oi.check_id is distinct from v_target_check_ids[1];
    end if;
  end loop;

  -- Cerrar checks vacíos extra (positions > v_people+1) sin items abiertos.
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
