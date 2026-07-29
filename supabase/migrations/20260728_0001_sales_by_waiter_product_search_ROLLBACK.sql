-- Rollback de 20260728_0001: restaura fn_sales_by_waiter sin p_search
-- (misma definición que 20260516_0002).

begin;

drop function if exists public.fn_sales_by_waiter(uuid, date, date, text);

create or replace function public.fn_sales_by_waiter(
  p_business_id uuid,
  p_from_date date,
  p_to_date date
)
returns table (
  employee_id uuid,
  employee_name text,
  orders_count bigint,
  items_count bigint,
  units numeric,
  gross_amount numeric,
  discounts_amount numeric,
  net_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_business_id is null then
    raise exception 'BUSINESS_ID_REQUIRED';
  end if;
  if p_from_date is null or p_to_date is null then
    raise exception 'DATE_RANGE_REQUIRED';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'UNAUTHORIZED_BUSINESS';
  end if;

  return query
  with attributed_items as (
    select
      coalesce(oi.created_by_employee_id, ts.opened_by_employee_id) as emp_id,
      oi.order_id,
      coalesce(oi.qty, oi.quantity::numeric, 0) as units,
      oi.subtotal,
      oi.tax,
      coalesce(oi.discounts, 0) as discounts,
      oi.id as item_id
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.table_sessions ts on ts.id = o.session_id
    where ts.business_id = p_business_id
      and oi.status <> 'void'
      and oi.created_at::date between p_from_date and p_to_date
      and coalesce(oi.created_by_employee_id, ts.opened_by_employee_id) is not null
  )
  select
    ai.emp_id as employee_id,
    e.first_name || coalesce(' ' || nullif(btrim(e.last_name), ''), '')
      as employee_name,
    count(distinct ai.order_id)::bigint as orders_count,
    count(ai.item_id)::bigint as items_count,
    sum(ai.units) as units,
    sum(ai.subtotal + ai.tax) as gross_amount,
    sum(ai.discounts) as discounts_amount,
    sum(ai.subtotal + ai.tax - ai.discounts) as net_amount
  from attributed_items ai
  join public.employees e on e.id = ai.emp_id
  group by ai.emp_id, e.first_name, e.last_name
  order by net_amount desc nulls last;
end;
$$;

grant execute on function public.fn_sales_by_waiter(uuid, date, date)
  to authenticated;

commit;
