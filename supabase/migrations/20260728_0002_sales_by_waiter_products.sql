-- =============================================================================
-- Reporte ventas por mesero: desglose de productos vendidos por cada mesero.
--
-- Nueva RPC `fn_sales_by_waiter_products` que devuelve una fila por
-- (empleado, producto) con unidades, items, bruto, descuentos y neto.
-- Misma atribución que fn_sales_by_waiter (created_by_employee_id con
-- fallback a opened_by_employee_id; sin atribución = excluido) y mismo
-- filtro opcional p_search por product_name/sku, para que el desglose
-- siempre cuadre con la tabla resumen.
--
-- Los productos se agrupan por nombre (product_name) porque order_items
-- guarda el nombre al momento de la venta; items viejos sin product_name
-- salen como 'Sin nombre'.
--
-- IDEMPOTENTE: CREATE OR REPLACE (función nueva, sin firma previa).
-- =============================================================================

begin;

create or replace function public.fn_sales_by_waiter_products(
  p_business_id uuid,
  p_from_date date,
  p_to_date date,
  p_search text default null
)
returns table (
  employee_id uuid,
  employee_name text,
  product_name text,
  sku text,
  units numeric,
  items_count bigint,
  gross_amount numeric,
  discounts_amount numeric,
  net_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
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
      coalesce(nullif(btrim(oi.product_name), ''), 'Sin nombre')
        as prod_name,
      oi.sku as prod_sku,
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
      and (
        v_search is null
        or oi.product_name ilike '%' || v_search || '%'
        or oi.sku ilike '%' || v_search || '%'
      )
  )
  select
    ai.emp_id as employee_id,
    e.first_name || coalesce(' ' || nullif(btrim(e.last_name), ''), '')
      as employee_name,
    ai.prod_name as product_name,
    max(ai.prod_sku) as sku,
    sum(ai.units) as units,
    count(ai.item_id)::bigint as items_count,
    sum(ai.subtotal + ai.tax) as gross_amount,
    sum(ai.discounts) as discounts_amount,
    sum(ai.subtotal + ai.tax - ai.discounts) as net_amount
  from attributed_items ai
  join public.employees e on e.id = ai.emp_id
  group by ai.emp_id, e.first_name, e.last_name, ai.prod_name
  order by employee_name asc, net_amount desc nulls last;
end;
$$;

grant execute on function public.fn_sales_by_waiter_products(uuid, date, date, text)
  to authenticated;

comment on function public.fn_sales_by_waiter_products(uuid, date, date, text) is
  'Desglose de productos vendidos por cada mesero. Una fila por '
  '(empleado, producto). Misma atribución y filtro p_search que '
  'fn_sales_by_waiter para que cuadre con el resumen.';

commit;
