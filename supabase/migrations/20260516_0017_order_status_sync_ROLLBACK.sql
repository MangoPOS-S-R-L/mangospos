-- Rollback de `20260516_0017_order_status_sync.sql`.
-- Restaura `fn_close_order_and_table` al comportamiento anterior (solo
-- toca status_ext, NO sincroniza status). El backfill aplicado no se
-- revierte — las órdenes ya corregidas se quedan con status='paid'
-- (eso está bien, no rompe nada).

begin;

create or replace function public.fn_close_order_and_table(
  p_order_id uuid,
  p_status public.order_status
) returns void
language plpgsql
security definer
set search_path = public
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

commit;
