-- 2026-03-22
-- Fix compat quantity on equal split so legacy/UI consumers never see 0 items
-- when qty is fractional (e.g. 0.5).
-- Decimal qty remains source of truth for totals; integer quantity is only
-- a compatibility/display field.

begin;

create or replace function public.fn_split_items_equally(
  p_order_id uuid,
  p_people integer
)
returns setof public.order_checks
language plpgsql
security definer
set search_path=public
as $$
declare
  v_people integer := coalesce(p_people, 0);
  v_idx integer;
  v_pos integer;
  v_item record;
  v_target_check_ids uuid[] := array[]::uuid[];
  v_item_qty numeric(10,3);
  v_item_discounts numeric(12,2);
  v_qty_base numeric(10,3);
  v_qty_share numeric(10,3);
  v_qty_accum numeric(10,3);
  v_discount_base numeric(12,2);
  v_discount_share numeric(12,2);
  v_discount_accum numeric(12,2);
  v_new_item_id uuid;
  v_modifiers jsonb;
  v_mod jsonb;
  v_mod_qty numeric(10,3);
  v_check_id uuid;
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

  perform pg_advisory_xact_lock(hashtext(p_order_id::text));

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

  for v_item in
    select oi.*
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
    order by oi.created_at, oi.id
  loop
    v_item_qty := round(greatest(coalesce(v_item.qty, v_item.quantity, 1), 0), 3);
    if v_item_qty <= 0 then
      continue;
    end if;

    v_item_discounts := coalesce(v_item.discounts, 0);
    v_qty_base := trunc(v_item_qty / v_people, 3);
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
        v_qty_share := round(v_item_qty - v_qty_accum, 3);
        v_discount_share := round(v_item_discounts - v_discount_accum, 2);
      end if;

      v_qty_share := greatest(v_qty_share, 0);
      v_discount_share := greatest(v_discount_share, 0);

      if v_idx = 1 then
        update public.order_items oi
        set
          check_id = v_target_check_ids[v_idx],
          qty = v_qty_share,
          quantity = greatest(ceil(v_qty_share), 1),
          discounts = v_discount_share
        where oi.id = v_item.id;

        delete from public.order_item_modifiers where item_id = v_item.id;

        for v_mod in select value from jsonb_array_elements(v_modifiers)
        loop
          v_mod_qty := round(
            coalesce((v_mod->>'qty')::numeric, 1) *
            case when v_item_qty = 0 then 0 else (v_qty_share / v_item_qty) end,
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
          greatest(ceil(v_qty_share), 1),
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
            case when v_item_qty = 0 then 0 else (v_qty_share / v_item_qty) end,
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
  end loop;

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
        and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
    );

  perform public.calculate_order_totals(p_order_id);
  for v_check_id in
    select oc.id
    from public.order_checks oc
    where oc.order_id = p_order_id
      and oc.position between 1 and (v_people + 1)
  loop
    perform public.calculate_check_totals(v_check_id);
  end loop;

  return query
  select *
  from public.order_checks oc
  where oc.order_id = p_order_id
    and oc.position between 2 and (v_people + 1)
  order by oc.position;
end;
$$;

grant execute on function public.fn_split_items_equally(uuid, integer) to authenticated;

commit;
