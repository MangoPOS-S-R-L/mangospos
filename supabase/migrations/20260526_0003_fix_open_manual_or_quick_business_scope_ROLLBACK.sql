-- =====================================================================
-- Rollback: restaurar fn_open_manual_or_quick a su firma original sin
-- p_business_id. Solo usar si la migracion 20260526_0003 introdujo un
-- problema; el bug original (Owner multi-tenant viendo ordenes que no
-- pertenecen al business activo) volvera a manifestarse.
-- =====================================================================

drop function if exists public.fn_open_manual_or_quick(public.order_origin, uuid, integer, uuid);

create or replace function public.fn_open_manual_or_quick(
  p_origin public.order_origin,
  p_user_id uuid,
  p_people_count integer default 1
) returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
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

  select business_id
    into v_business_id
  from public.user_businesses
  where user_id = v_user_id
  order by created_at
  limit 1;

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

alter function public.fn_open_manual_or_quick(
  public.order_origin, uuid, integer
) owner to postgres;

grant execute on function public.fn_open_manual_or_quick(
  public.order_origin, uuid, integer
) to authenticated;
grant execute on function public.fn_open_manual_or_quick(
  public.order_origin, uuid, integer
) to service_role;

notify pgrst, 'reload schema';
