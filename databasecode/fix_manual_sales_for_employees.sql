-- Fix fn_open_manual_or_quick to support employees
-- This function now checks both user_businesses AND employees tables

CREATE OR REPLACE FUNCTION public.fn_open_manual_or_quick(
  p_origin public.order_origin,
  p_user_id uuid,
  p_people_count int default 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_user_id uuid := coalesce(p_user_id, auth.uid());
  v_business_id uuid;
  v_table_id uuid;
  v_session_id uuid;
  v_order_id uuid;
  v_existing_session uuid;
  v_open_order_id uuid;
begin
  if v_user_id is null then
    raise exception 'fn_open_manual_or_quick: user id is required';
  end if;

  -- Try to get business_id from user_businesses first
  select business_id
    into v_business_id
  from public.user_businesses
  where user_id = v_user_id
  order by created_at
  limit 1;

  -- If not found, try employees table
  if v_business_id is null then
    select business_id
      into v_business_id
    from public.employees
    where user_id = v_user_id
    limit 1;
  end if;

  -- If still not found, try current_user_business_ids function
  if v_business_id is null then
    select bid
      into v_business_id
    from public.current_user_business_ids() as bid
    limit 1;
  end if;

  if v_business_id is null then
    raise exception 'fn_open_manual_or_quick: no business found for user %', v_user_id;
  end if;

  v_table_id := public.fn_get_or_create_virtual_table(v_business_id, p_origin);

  -- Close any previous open session on this virtual table
  select id
    into v_existing_session
  from public.table_sessions
  where table_id = v_table_id
    and closed_at is null
  limit 1;

  if v_existing_session is not null then
    for v_open_order_id in
      select id
      from public.orders
      where session_id = v_existing_session
        and status_ext = 'open'
    loop
      perform public.fn_close_order_and_table(v_open_order_id, 'void');
    end loop;

    update public.table_sessions
    set closed_at = now()
    where id = v_existing_session;
  end if;

  insert into public.table_sessions (table_id, opened_by, origin, waiter_user_id, people_count)
  values (v_table_id, v_user_id, p_origin, v_user_id, greatest(1, p_people_count))
  returning id into v_session_id;

  insert into public.orders (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
  values (v_session_id, 'open', 0, 0, 0, 0, 0)
  returning id into v_order_id;

  insert into public.order_checks (order_id, label, position)
  values (v_order_id, 'C1', 1);

  return jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
end;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.fn_open_manual_or_quick(public.order_origin, uuid, int) TO authenticated;
