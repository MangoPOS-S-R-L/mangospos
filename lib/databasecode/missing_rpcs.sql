-- 🥭 MangoPOS - Missing RPC Functions
-- Run this script in your Supabase SQL Editor to define the missing functions.

-- 0. 🪑 Open Table (reutiliza orden activa si existe)
create or replace function public.fn_open_table(
  p_table_id uuid,
  p_user_id uuid,               -- auth.users.id del mesero que clickea
  p_people_count int default 1
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session_id uuid;
  v_order_id uuid;
begin
  -- Si ya hay sesión abierta, reusarla
  select id into v_session_id
  from public.table_sessions
  where table_id = p_table_id and closed_at is null
  order by opened_at desc
  limit 1;

  if v_session_id is null then
    insert into public.table_sessions(table_id, opened_by, origin, waiter_user_id, people_count)
    values (p_table_id, p_user_id, 'dine_in', p_user_id, greatest(1, p_people_count))
    returning id into v_session_id;
  end if;

  -- Marcar la mesa como ocupada
  update public.dining_tables
  set state = 'occupied'
  where id = p_table_id;

  -- Orden activa (si no existe, crear una nueva)
  select id into v_order_id
  from public.orders
  where session_id = v_session_id
    and closed_at is null
    and status_ext not in ('paid', 'void')
  order by created_at desc limit 1;

  if v_order_id is null then
    insert into public.orders(session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    values (v_session_id, 'open', 0, 0, 0, 0, 0)
    returning id into v_order_id;

    -- C1 por defecto
    insert into public.order_checks(order_id, label, position)
    values (v_order_id, 'C1', 1);
  end if;

  return jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
end $$;

grant execute on function public.fn_open_table(uuid, uuid, int) to authenticated;

-- 0.1 🧾 Add item from menu (insert as draft so only new items go to kitchen)
create or replace function public.fn_add_item_from_menu(
  p_order_id uuid,
  p_menu_item_id uuid,
  p_qty numeric default 1,
  p_check_position int default 1,
  p_is_takeout boolean default false,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_name text;
  v_price numeric(12,2);
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
begin
  v_qty := greatest(coalesce(p_qty, 1), 1);

  select name, price
    into v_name, v_price
  from public.menu_items
  where id = p_menu_item_id
  limit 1;

  if v_name is null then
    raise exception 'MENU_ITEM_NOT_FOUND';
  end if;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  insert into public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, is_takeout, notes, status
  ) values (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, greatest(round(v_qty), 1)::int, v_price, coalesce(p_is_takeout, false), p_notes, 'draft'
  )
  returning id into v_item_id;

  perform public.fn_recalc_order_totals(p_order_id);
  return v_item_id;
end;
$$;

grant execute on function public.fn_add_item_from_menu(uuid, uuid, numeric, int, boolean, text)
  to authenticated;


-- 1. 🍽️ Confirm Order to Kitchen
create or replace function public.fn_confirm_order_to_kitchen(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  -- Update order status
  update public.orders
  set status = 'sent',
      status_ext = 'sent_to_kitchen'
  where id = p_order_id;

  -- Update items status (only those that were draft/pending)
  update public.order_items
  set status = 'pending' -- 'pending' means sent to kitchen but not yet cooking
  where order_id = p_order_id
    and status in ('draft', 'open');
end;
$$;

grant execute on function public.fn_confirm_order_to_kitchen(uuid) to authenticated;


-- 2. 🧾 Create Split Bill
create or replace function public.fn_create_split_bill(p_order_id uuid, p_number_of_checks int)
returns setof public.order_checks
language plpgsql
security definer
set search_path=public
as $$
declare
  v_i int;
  v_check_id uuid;
begin
  -- Create checks
  for v_i in 1..p_number_of_checks loop
    insert into public.order_checks(order_id, label, position, is_closed)
    values (p_order_id, 'Cuenta ' || v_i, v_i, false)
    returning id into v_check_id;
  end loop;

  -- Return all checks for this order
  return query
  select * from public.order_checks
  where order_id = p_order_id
  order by position;
end;
$$;

grant execute on function public.fn_create_split_bill(uuid, int) to authenticated;


-- 3. 💰 Process Payment
create or replace function public.fn_process_payment(
  p_order_id uuid,
  p_check_id uuid,
  p_payment_method_id text, -- ID or code of payment method
  p_amount numeric,
  p_reference text,
  p_customer_id uuid default null,
  p_customer_rnc text default null
)
returns public.payments
language plpgsql
security definer
set search_path=public
as $$
declare
  v_payment public.payments;
  v_business_id uuid;
  v_session_id uuid;
  v_payment_method_id uuid;
begin
  select session_id into v_session_id from public.orders where id = p_order_id;
  -- Get business_id from order->session->table->zone OR current user context
  -- Simplest is to fetch from order ownership, but here let's assume we can get it from context or passed.
  -- For now, we'll try to get it from table_session
  select z.business_id into v_business_id
  from public.orders o
  join public.table_sessions ts on o.session_id = ts.id
  join public.dining_tables dt on ts.table_id = dt.id
  join public.zones z on dt.zone_id = z.id
  where o.id = p_order_id;

  -- Resolver payment_method_id (uuid o code)
  if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
    v_payment_method_id := p_payment_method_id::uuid;
  else
    select pm.id into v_payment_method_id
    from public.payment_methods pm
    where pm.business_id = v_business_id
      and pm.code = p_payment_method_id
      and pm.is_active = true
    limit 1;
  end if;

  if v_payment_method_id is null then
    raise exception 'Metodo de pago no valido: %', p_payment_method_id;
  end if;

  insert into public.payments(
    business_id, order_id, check_id, payment_method_id, amount, reference, status, session_id, created_at
  )
  values (
    v_business_id, p_order_id, p_check_id, v_payment_method_id, p_amount, p_reference, 'completed', v_session_id, now()
  )
  returning * into v_payment;

  perform public.fn_close_order_and_table(p_order_id, 'paid');

  return v_payment;
end;
$$;

grant execute on function public.fn_process_payment(uuid, uuid, text, numeric, text, uuid, text) to authenticated;

-- 3.1 dY'ř Process Payment v2 (compat con pagos + caja)
create or replace function public.fn_process_payment_v2(
  p_order_id uuid,
  p_check_id uuid,
  p_payment_method_id text, -- ID or code of payment method
  p_amount numeric,
  p_reference text,
  p_customer_id uuid default null,
  p_customer_rnc text default null,
  p_cashier_session_id uuid default null
)
returns public.payments
language plpgsql
security definer
set search_path=public
as $$
declare
  v_payment public.payments;
  v_business_id uuid;
  v_table_session_id uuid;
  v_payment_method_id uuid;
begin
  select o.session_id into v_table_session_id
  from public.orders o
  where o.id = p_order_id;

  -- Buscar business_id desde la mesa/zona (evita depender de orders.business_id)
  select z.business_id into v_business_id
  from public.table_sessions ts
  join public.dining_tables dt on dt.id = ts.table_id
  join public.zones z on z.id = dt.zone_id
  where ts.id = v_table_session_id;

  -- Fallback si no hay mesa (manual/quick) o no se pudo resolver
  if v_business_id is null then
    select bid into v_business_id
    from public.current_user_business_ids() as bid
    limit 1;
  end if;

  -- Resolver payment_method_id (uuid o code)
  if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
    v_payment_method_id := p_payment_method_id::uuid;
  else
    select pm.id into v_payment_method_id
    from public.payment_methods pm
    where pm.business_id = v_business_id
      and pm.code = p_payment_method_id
      and pm.is_active = true
    limit 1;
  end if;

  if v_payment_method_id is null then
    raise exception 'Metodo de pago no valido: %', p_payment_method_id;
  end if;

  insert into public.payments(
    business_id,
    order_id,
    check_id,
    payment_method_id,
    amount,
    reference,
    change_amount,
    status,
    processed_by,
    session_id,
    created_at
  )
  values (
    v_business_id,
    p_order_id,
    p_check_id,
    v_payment_method_id,
    p_amount,
    p_reference,
    0,
    'completed',
    auth.uid(),
    coalesce(p_cashier_session_id, v_table_session_id),
    now()
  )
  returning * into v_payment;

  perform public.fn_close_order_and_table(p_order_id, 'paid');

  return v_payment;
end;
$$;

grant execute on function public.fn_process_payment_v2(uuid, uuid, text, numeric, text, uuid, text, uuid) to authenticated;

-- 3.3 🍳 Kitchen: iniciar preparacion por orden
create or replace function public.fn_start_preparing_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  update public.order_items
  set status = 'preparing',
      started_at = now()
  where order_id = p_order_id
    and status in ('pending');
end;
$$;

grant execute on function public.fn_start_preparing_order(uuid) to authenticated;

-- 3.4 ✅ Kitchen: marcar orden lista
create or replace function public.fn_mark_order_ready(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  update public.order_items
  set status = 'ready',
      ready_at = now()
  where order_id = p_order_id
    and status in ('preparing');
end;
$$;

grant execute on function public.fn_mark_order_ready(uuid) to authenticated;

-- 3.2 dY'_, Cerrar orden y liberar mesa
create or replace function public.fn_close_order_and_table(
  p_order_id uuid,
  p_status public.order_status -- 'paid' o 'void'
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session uuid;
  v_open_count int;
  v_table_id uuid;
begin
  update public.orders
  set status_ext = p_status,
      closed_at = now()
  where id = p_order_id;

  select session_id into v_session from public.orders where id = p_order_id;
  select table_id into v_table_id from public.table_sessions where id = v_session;

  select count(*) into v_open_count
  from public.orders
  where session_id = v_session
    and closed_at is null
    and status_ext not in ('paid', 'void');

  if coalesce(v_open_count, 0) = 0 then
    update public.table_sessions
    set closed_at = now()
    where id = v_session and closed_at is null;

    if v_table_id is not null then
      update public.dining_tables
      set state = 'available'
      where id = v_table_id;
    end if;
  end if;
end;
$$;

grant execute on function public.fn_close_order_and_table(uuid, public.order_status) to authenticated;


-- 4. 📄 Create Fiscal Document (Stub)
create or replace function public.create_fiscal_document(
  p_order_id uuid,
  p_payment_id uuid,
  p_customer_id uuid,
  p_customer_rnc text
)
returns public.fiscal_documents
language plpgsql
security definer
set search_path=public
as $$
declare
  v_doc public.fiscal_documents;
  v_business_id uuid;
  v_total numeric;
  v_tax numeric;
  v_subtotal numeric;
begin
  -- Get order details
  select subtotal, tax, total into v_subtotal, v_tax, v_total
  from public.orders where id = p_order_id;

  -- Mock NCF generation
  insert into public.fiscal_documents(
    business_id, order_id, payment_id, customer_id, customer_rnc,
    ncf_type, ncf_number, total, subtotal, itbis_amount, status
  )
  select
    b.id, p_order_id, p_payment_id, p_customer_id, p_customer_rnc,
    'B02', 'B0200000001', -- MOCK
    v_total, v_subtotal, v_tax, 'issued'
  from public.businesses b
  limit 1 -- Fallback logic needed for real business_id
  returning * into v_doc;

  return v_doc;
end;
$$;

grant execute on function public.create_fiscal_document(uuid, uuid, uuid, text) to authenticated;
