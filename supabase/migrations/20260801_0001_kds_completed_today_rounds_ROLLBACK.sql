-- =============================================================================
-- ROLLBACK de 20260801_0001 — vuelve fn_kds_completed_today a la firma de
-- 20260729_0002 (sin kitchen_sent_at).
-- =============================================================================
--
-- La app degrada sola: sin la columna, los ítems del historial llegan con
-- kitchen_sent_at null y "Completados hoy" vuelve a agrupar por orden.
-- No hace falta revertir el build.
-- =============================================================================

begin;

drop function if exists public.fn_kds_completed_today(uuid);

create function public.fn_kds_completed_today(
  p_business_id uuid
)
returns table (
  id uuid,
  order_id uuid,
  order_number text,
  product_name text,
  quantity numeric,
  notes text,
  status text,
  created_at timestamptz,
  started_at timestamptz,
  ready_at timestamptz,
  table_name text,
  waiter_name text,
  business_id uuid,
  area_code text,
  area_name text,
  is_takeout boolean
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_business_id is null then
    raise exception 'BUSINESS_ID_REQUIRED';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'UNAUTHORIZED_BUSINESS';
  end if;

  return query
  select
    oi.id,
    oi.order_id,
    left(oi.order_id::text, 8) as order_number,
    oi.product_name,
    coalesce(oi.quantity::numeric, oi.qty, 1::numeric) as quantity,
    oi.notes,
    oi.status::text as status,
    oi.created_at,
    oi.started_at,
    coalesce(oi.ready_at, o.closed_at) as ready_at,
    case
      when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
      when ts.origin = 'manual'::public.order_origin then 'Venta manual'
      when ts.origin = 'quick'::public.order_origin  then 'Venta rapida'
      else 'Venta'
    end as table_name,
    p.full_name as waiter_name,
    o.business_id,
    oi.print_area_code as area_code,
    pa.name as area_name,
    oi.is_takeout
  from public.order_items oi
  join public.orders o          on o.id = oi.order_id
  join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.profiles p       on p.id = ts.waiter_user_id
  left join public.print_areas pa
         on pa.code = oi.print_area_code
        and pa.business_id = o.business_id
  where o.business_id = p_business_id
    and oi.status <> 'void'::public.item_status
    and (
      (oi.ready_at is not null
       and (oi.ready_at at time zone 'America/Santo_Domingo')::date
           = (now() at time zone 'America/Santo_Domingo')::date)
      or (oi.ready_at is null
          and oi.kitchen_sent_at is not null
          and oi.status in ('paid'::public.item_status,
                            'served'::public.item_status)
          and o.closed_at is not null
          and (o.closed_at at time zone 'America/Santo_Domingo')::date
              = (now() at time zone 'America/Santo_Domingo')::date)
    );
end;
$$;

grant execute on function public.fn_kds_completed_today(uuid) to authenticated;

commit;
