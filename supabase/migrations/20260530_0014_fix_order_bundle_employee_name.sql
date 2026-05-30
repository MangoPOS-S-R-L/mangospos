-- =============================================================================
-- Migración: fix_order_bundle_employee_name
--
-- Corrige fn_get_order_bundle para incluir el join de public.employees
-- embebido en cada order_item (bajo la clave 'employees').
-- Esto permite que la app en Flutter (que lee el bundle vía fn_get_order_bundle
-- y fn_open_table_and_load) reciba directamente los nombres de los mozos que
-- agregaron cada producto sin requerir consultas RLS directas adicionales.
-- =============================================================================

begin;

create or replace function public.fn_get_order_bundle(
  p_order_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payload jsonb;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  with target_order as (
    select o.*
    from public.orders o
    where o.id = p_order_id
    limit 1
  ),
  order_customer as (
    select ts.customer_id, ts.customer_name
    from target_order o
    join public.table_sessions ts on ts.id = o.session_id
  )
  select jsonb_build_object(
    'order',
      (select to_jsonb(o) from target_order o),
    'checks',
      coalesce(
        (
          select jsonb_agg(to_jsonb(oc) order by oc.position)
          from public.order_checks oc
          where oc.order_id = p_order_id
        ),
        '[]'::jsonb
      ),
    'items',
      coalesce(
        (
          select jsonb_agg(
            to_jsonb(oi) || jsonb_build_object(
              'employees', (
                select jsonb_build_object(
                  'first_name', e.first_name,
                  'last_name', e.last_name
                )
                from public.employees e
                where e.id = oi.created_by_employee_id
              )
            )
            order by oi.created_at, oi.id
          )
          from public.order_items oi
          join target_order o on o.id = oi.order_id
          where oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
            and (o.closed_at is null or o.status_ext not in ('void', 'paid'))
        ),
        '[]'::jsonb
      ),
    'customer_id',
      (select customer_id from order_customer limit 1),
    'customer_name',
      (select customer_name from order_customer limit 1)
  )
  into v_payload;

  if v_payload is null or (v_payload -> 'order') is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  return v_payload;
end;
$$;

grant execute on function public.fn_get_order_bundle(uuid) to authenticated;

commit;
