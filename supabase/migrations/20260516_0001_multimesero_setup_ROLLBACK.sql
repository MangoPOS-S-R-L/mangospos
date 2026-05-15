-- =============================================================================
-- ROLLBACK de `20260516_0001_multimesero_setup.sql`.
--
-- Revierte el setup del modo multimesero.
--
-- ⚠️ ADVERTENCIA:
--   Si después de aplicar la migration ya se crearon sessions/items con
--   `opened_by_employee_id` / `created_by_employee_id`, esos datos se PIERDEN
--   al dropear las columnas. Si necesitás conservar la trazabilidad, exportá
--   antes:
--     select id, opened_by_employee_id from table_sessions
--       where opened_by_employee_id is not null;
--     select id, created_by_employee_id from order_items
--       where created_by_employee_id is not null;
-- =============================================================================

begin;

-- 1. Restaurar fn_open_table a su versión original (sin p_opened_by_employee_id)
drop function if exists public.fn_open_table(uuid, uuid, integer, uuid);

create function public.fn_open_table(
  p_table_id uuid,
  p_user_id uuid,
  p_people_count integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session_id uuid;
  v_order_id uuid;
  v_user_id uuid;
begin
  if p_table_id is null then
    raise exception 'TABLE_ID_REQUIRED';
  end if;

  if auth.uid() is not null and p_user_id is not null and p_user_id <> auth.uid() then
    raise exception 'INVALID_USER_CONTEXT';
  end if;

  v_user_id := coalesce(auth.uid(), p_user_id);

  if v_user_id is null then
    raise exception 'USER_REQUIRED';
  end if;

  perform public.fn_require_open_cash_session(v_user_id);

  perform pg_advisory_xact_lock(hashtextextended(p_table_id::text, 0));

  select ts.id
    into v_session_id
  from public.table_sessions ts
  where ts.table_id = p_table_id
    and ts.closed_at is null
  order by ts.opened_at desc
  limit 1;

  if v_session_id is null then
    insert into public.table_sessions (table_id, opened_by, origin, waiter_user_id, people_count)
    values (p_table_id, v_user_id, 'dine_in', v_user_id, greatest(1, coalesce(p_people_count, 1)))
    returning id into v_session_id;
  end if;

  update public.dining_tables
     set state = 'occupied'
   where id = p_table_id
     and state is distinct from 'occupied';

  select o.id
    into v_order_id
  from public.orders o
  where o.session_id = v_session_id
    and o.closed_at is null
    and o.status_ext not in ('paid', 'void')
  order by o.created_at desc
  limit 1;

  if v_order_id is null then
    insert into public.orders (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    values (v_session_id, 'open', 0, 0, 0, 0, 0)
    returning id into v_order_id;

    insert into public.order_checks (order_id, label, position)
    values (v_order_id, 'C1', 1)
    on conflict (order_id, position) do nothing;
  end if;

  return jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
end;
$$;

grant execute on function public.fn_open_table(uuid, uuid, integer) to authenticated;

-- 2. Drop fn_verify_employee_pin
drop function if exists public.fn_verify_employee_pin(uuid, text);

-- 3. Drop UNIQUE index de PINs
drop index if exists public.employees_business_pin_unique;

-- 4. Drop columnas y FKs
alter table public.order_items
  drop constraint if exists order_items_created_by_employee_fk;
drop index if exists public.idx_order_items_created_by_employee;
alter table public.order_items
  drop column if exists created_by_employee_id;

alter table public.table_sessions
  drop constraint if exists table_sessions_opened_by_employee_fk;
drop index if exists public.idx_table_sessions_opened_by_employee;
alter table public.table_sessions
  drop column if exists opened_by_employee_id;

-- 5. Drop business_settings.multimesero_enabled
alter table public.business_settings
  drop column if exists multimesero_enabled;

commit;
