-- =============================================================================
-- Reporte ventas por mesero: filtro por producto.
--
-- Agrega `p_search` a fn_sales_by_waiter para poder filtrar los items por
-- nombre de producto (o SKU). Con p_search null/vacío el comportamiento es
-- idéntico al anterior. Los totales (órdenes, items, bruto, neto) pasan a
-- reflejar SOLO los items que matchean el término.
--
-- FIX anulaciones: excluye órdenes con status_ext = 'void'. La anulación
-- desde la pantalla de mesa (fn_close_order_and_table) marca la ORDEN como
-- void pero NO los items, así que esos items (y sus descuentos) entraban
-- al reporte. El filtro item-level `status <> 'void'` se mantiene para el
-- flujo de historial de ventas, que sí anula item por item.
--
-- IMPORTANTE: se hace DROP de la firma vieja (uuid, date, date) antes de
-- crear la nueva (uuid, date, date, text default null). Si quedaran ambas,
-- PostgREST no puede resolver la llamada por nombre (PGRST203 ambiguous).
-- Como p_search tiene default, las llamadas viejas con 3 parámetros siguen
-- funcionando.
--
-- IDEMPOTENTE: drop if exists + create or replace.
-- =============================================================================

begin;

drop function if exists public.fn_sales_by_waiter(uuid, date, date);

create or replace function public.fn_sales_by_waiter(
  p_business_id uuid,
  p_from_date date,
  p_to_date date,
  p_search text default null
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
      and o.status_ext is distinct from 'void'
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

grant execute on function public.fn_sales_by_waiter(uuid, date, date, text)
  to authenticated;

comment on function public.fn_sales_by_waiter(uuid, date, date, text) is
  'Reporte de ventas por mesero. Atribuye cada item al empleado que lo '
  'agregó (created_by_employee_id), con fallback al que abrió la mesa '
  '(opened_by_employee_id). Items sin ninguna atribución quedan excluidos. '
  'p_search filtra items por product_name/sku (ilike).';

commit;
