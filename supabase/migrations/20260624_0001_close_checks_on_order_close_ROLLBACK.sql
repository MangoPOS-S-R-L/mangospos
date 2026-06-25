-- ROLLBACK de 20260624_0001_close_checks_on_order_close.sql
-- Restaura fn_close_order_and_table SIN el cierre atómico de checks
-- (versión viva previa al fix). OJO: revertir reintroduce el bug de
-- checks huérfanos abiertos tras un cobro a nivel de orden.

CREATE OR REPLACE FUNCTION public.fn_close_order_and_table(p_order_id uuid, p_status order_status)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_session uuid;
  v_open_count int;
  v_table_id uuid;
  v_legacy_status text;
begin
  v_legacy_status := case p_status
    when 'paid'::public.order_status then 'paid'
    when 'void'::public.order_status then 'canceled'
    else null
  end;

  update public.orders
  set status_ext = p_status,
      status     = coalesce(v_legacy_status, status),
      closed_at  = now()
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
$function$;
