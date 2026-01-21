-- Open table and mark it as occupied
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
  -- Si ya hay sesion abierta, reusala
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
