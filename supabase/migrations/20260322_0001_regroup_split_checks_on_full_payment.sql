-- 2026-03-22
-- Cuando una orden con cuentas divididas se cobra completa (sin p_check_id),
-- reagrupar los items cerrando las subcuentas para dejar la venta consistente
-- para historial, reimpresiones y reportes.

begin;

create or replace function public.fn_process_payment_v3(
  p_order_id uuid,
  p_check_id uuid,
  p_payment_method_id text,
  p_amount numeric,
  p_reference text,
  p_customer_id uuid default null,
  p_customer_rnc text default null,
  p_cashier_session_id uuid default null,
  p_change_amount numeric default 0
) returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
  v_business_id uuid;
  v_table_session_id uuid;
  v_payment_method_id uuid;
  v_payment_method_code text;
  v_open_items_count bigint := 0;
  v_cash_in_drawer numeric := 0;
begin
  select o.session_id
    into v_table_session_id
  from public.orders o
  where o.id = p_order_id;

  if v_table_session_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  select ts.business_id
    into v_business_id
  from public.table_sessions ts
  where ts.id = v_table_session_id;

  if v_business_id is null then
    select bid
      into v_business_id
    from public.current_user_business_ids() as bid
    limit 1;
  end if;

  if v_business_id is null then
    raise exception 'BUSINESS_NOT_FOUND';
  end if;

  if p_cashier_session_id is null then
    raise exception 'CASH_SESSION_REQUIRED';
  end if;

  perform 1
  from public.cash_register_sessions s
  where s.id = p_cashier_session_id
    and s.status = 'open'
    and s.closed_at is null;

  if not found then
    raise exception 'CASH_SESSION_NOT_OPEN';
  end if;

  if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
    select pm.id, pm.code
      into v_payment_method_id, v_payment_method_code
    from public.payment_methods pm
    where pm.id = p_payment_method_id::uuid
      and pm.is_active = true
    limit 1;
  else
    select pm.id, pm.code
      into v_payment_method_id, v_payment_method_code
    from public.payment_methods pm
    where pm.business_id = v_business_id
      and pm.code = p_payment_method_id
      and pm.is_active = true
    limit 1;
  end if;

  if v_payment_method_id is null then
    raise exception 'INVALID_PAYMENT_METHOD';
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
    customer_id,
    customer_rnc,
    created_at
  )
  values (
    v_business_id,
    p_order_id,
    p_check_id,
    v_payment_method_id,
    p_amount,
    p_reference,
    coalesce(p_change_amount, 0),
    'completed',
    auth.uid(),
    p_cashier_session_id,
    p_customer_id,
    p_customer_rnc,
    now()
  )
  returning * into v_payment;

  if p_check_id is not null then
    update public.order_items
    set status = 'paid'
    where order_id = p_order_id
      and check_id = p_check_id
      and status <> 'void';

    update public.order_checks
    set is_closed = true,
        closed_at = now()
    where id = p_check_id;

    select count(*)
      into v_open_items_count
    from public.order_items
    where order_id = p_order_id
      and status not in ('paid', 'void');

    if v_open_items_count = 0 then
      perform public.fn_close_order_and_table(p_order_id, 'paid');
    end if;
  else
    update public.order_items
    set status = 'paid',
        check_id = null
    where order_id = p_order_id
      and status <> 'void';

    update public.order_checks
    set is_closed = true,
        closed_at = coalesce(closed_at, now())
    where order_id = p_order_id
      and is_closed = false;

    perform public.fn_close_order_and_table(p_order_id, 'paid');
  end if;

  if v_payment_method_code = 'cash' then
    v_cash_in_drawer := greatest(
      coalesce(p_amount, 0) - coalesce(p_change_amount, 0),
      0
    );

    if v_cash_in_drawer > 0 then
      insert into public.cash_transactions(
        session_id,
        amount,
        type,
        description,
        related_order_id
      )
      values (
        p_cashier_session_id,
        v_cash_in_drawer,
        'sale',
        'Venta ' || left(p_order_id::text, 8),
        p_order_id
      );
    end if;
  end if;

  return v_payment;
end;
$$;

grant all on function public.fn_process_payment_v3(
  uuid,
  uuid,
  text,
  numeric,
  text,
  uuid,
  text,
  uuid,
  numeric
) to anon;
grant all on function public.fn_process_payment_v3(
  uuid,
  uuid,
  text,
  numeric,
  text,
  uuid,
  text,
  uuid,
  numeric
) to authenticated;
grant all on function public.fn_process_payment_v3(
  uuid,
  uuid,
  text,
  numeric,
  text,
  uuid,
  text,
  uuid,
  numeric
) to service_role;

commit;
