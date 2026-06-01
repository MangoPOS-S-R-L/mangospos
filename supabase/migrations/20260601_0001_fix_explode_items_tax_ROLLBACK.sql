-- =============================================================================
-- ROLLBACK de 20260601_0001_fix_explode_items_tax.sql
-- Restaura fn_explode_items_to_units a su versión previa (20260513_0011),
-- donde las units 2..N se insertan SIN impuesto (tax_rate=0) y sin refrescar
-- tax_lines. Sólo usar si el fix introduce una regresión inesperada.
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
      and coalesce(oi.qty, oi.quantity, 1) =
          round(coalesce(oi.qty, oi.quantity, 1))
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

    select coalesce(
      jsonb_agg(
        jsonb_build_object('name', m.name, 'qty', m.qty, 'price', m.price)
      ),
      '[]'::jsonb
    )
    into v_modifiers
    from public.order_item_modifiers m
    where m.item_id = v_item.id;

    if jsonb_array_length(coalesce(v_modifiers, '[]'::jsonb)) > 0 then
      delete from public.order_item_modifiers where item_id = v_item.id;
    end if;

    update public.order_items oi
    set qty = 1,
        quantity = 1,
        discounts = v_base_discount
    where oi.id = v_item.id;

    v_new_item_id := v_item.id;
    v_discount_remaining := v_discount_remaining - v_base_discount;

    for v_mod in select value from jsonb_array_elements(v_modifiers)
    loop
      v_mod_qty_per_unit := round(
        coalesce((v_mod->>'qty')::numeric, 1) / v_total_qty::numeric, 3
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

    for v_idx in 2..v_total_qty loop
      if v_idx = v_total_qty then
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

      for v_mod in select value from jsonb_array_elements(v_modifiers)
      loop
        v_mod_qty_per_unit := round(
          coalesce((v_mod->>'qty')::numeric, 1) / v_total_qty::numeric, 3
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

commit;
