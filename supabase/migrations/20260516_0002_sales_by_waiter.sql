-- =============================================================================
-- Reporte: ventas por mesero (multimesero feature).
--
-- CONCEPTO:
--   Cada `order_items` puede traer `created_by_employee_id` (el mesero que
--   agregó esa línea, modo multimesero). Si está null, hacemos fallback al
--   `table_sessions.opened_by_employee_id` (el mesero que abrió la mesa).
--   Si AMBOS están null, el item no se atribuye a ningún mesero — queda
--   excluido del reporte por mesero (esos son items de modo single-mesero
--   o pre-multimesero).
--
-- ENTREGA:
--   1. RPC `fn_sales_by_waiter(business_id, from_date, to_date)` que devuelve
--      filas agrupadas por empleado con totales de items, unidades, bruto,
--      descuentos y neto.
--
-- SEGURIDAD:
--   SECURITY DEFINER, valida que el caller pertenezca al business.
--   Sin esto cualquier usuario podría sondear ventas de otros negocios.
--
-- IDEMPOTENTE: CREATE OR REPLACE.
-- =============================================================================

begin;

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

comment on function public.fn_sales_by_waiter(uuid, date, date) is
  'Reporte de ventas por mesero. Atribuye cada item al empleado que lo '
  'agregó (created_by_employee_id), con fallback al que abrió la mesa '
  '(opened_by_employee_id). Items sin ninguna atribución quedan excluidos.';

commit;
