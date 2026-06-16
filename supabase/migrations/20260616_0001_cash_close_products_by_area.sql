-- =============================================================================
-- 20260616_0001 — Desglose de productos por área de producción en el cierre
-- =============================================================================
--
-- Agrega al ticket de CIERRE DE CAJA un desglose que, por cada área de
-- producción (Bar, Cocina, …), lista CADA producto con su cantidad vendida
-- (unidades) en el periodo de la sesión. Es el complemento por-producto de la
-- sección "Ventas por área de producción" (que solo muestra totales por área).
--
-- Dos piezas, ambas ADITIVAS (no tocan nada existente):
--   1. business_settings.cash_close_print_products_by_area — toggle por negocio
--      (default false → no cambia el ticket de nadie sin opt-in).
--   2. get_products_by_production_area(business, from, to) — RPC NUEVA y
--      autocontenida. Reusa el MISMO scoping de pagos/órdenes que
--      get_sales_summary_v2 para que las cantidades concilien con esa sección,
--      pero agrupa por (área, producto). NO modifica get_sales_summary_v2.
--
-- Safe deploy: Flutter cae al default `false` si la columna no existe y omite
-- la sección si la RPC falla; el cierre sigue imprimiendo normalmente.
-- Sin impacto fiscal: no toca emisión, NCF ni fiscal_documents.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists cash_close_print_products_by_area boolean
    not null default false;

comment on column public.business_settings.cash_close_print_products_by_area is
  'Si true, el ticket de cierre de caja incluye un desglose por área de '
  'producción listando cada producto y su cantidad (unidades) en el periodo '
  'de la sesión. Default false.';

create or replace function public.get_products_by_production_area(
  _business_id uuid,
  _from        timestamp with time zone,
  _to          timestamp with time zone
)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare result jsonb;
begin
  -- Access check idéntico al de get_sales_summary_v2: service_role salta,
  -- authenticated debe pertenecer al negocio.
  if auth.role() != 'service_role' then
    if not exists (
      select 1 from current_user_business_ids() c
      where c.business_id = _business_id
    ) then
      raise exception 'access denied' using errcode = '42501';
    end if;
  end if;

  with
  -- Pagos del periodo (mismo criterio que el resumen de ventas).
  scoped_payments as (
    select p.order_id, p.status
    from payments p
    where p.business_id = _business_id
      and p.created_at >= _from
      and p.created_at <  _to
  ),
  completed_payments as (
    select * from scoped_payments where status = 'completed' or status is null
  ),
  order_ids as (
    select distinct order_id
    from completed_payments
    where order_id is not null
  ),
  -- Ítems no anulados de esas órdenes, con su área de producción legible.
  scoped_items as (
    select
      coalesce(pa.name, nullif(oi.print_area_code, ''), 'Sin área') as area_name,
      oi.product_name,
      coalesce(nullif(oi.qty, 0), oi.quantity, 0) as qty
    from order_items oi
    left join print_areas pa
      on pa.business_id = _business_id and pa.code = oi.print_area_code
    where oi.business_id = _business_id
      and oi.order_id in (select order_id from order_ids)
      and oi.status != 'void'
  ),
  by_area_product as (
    select area_name, product_name,
      coalesce(sum(qty), 0) as quantity
    from scoped_items
    group by area_name, product_name
    having coalesce(sum(qty), 0) > 0
  ),
  by_area as (
    select area_name,
      sum(quantity) as area_quantity,
      jsonb_agg(
        jsonb_build_object('product', product_name, 'quantity', quantity)
        order by quantity desc, product_name
      ) as products
    from by_area_product
    group by area_name
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'label', area_name,
        'quantity', area_quantity,
        'products', products
      )
      order by area_quantity desc, area_name
    ),
    '[]'::jsonb)
  into result
  from by_area;

  return result;
end;
$function$;

grant execute on function
  public.get_products_by_production_area(uuid, timestamp with time zone, timestamp with time zone)
  to authenticated, service_role;

comment on function
  public.get_products_by_production_area(uuid, timestamp with time zone, timestamp with time zone) is
  'Desglose por área de producción → productos con cantidad (unidades) para el '
  'cierre de caja. Mismo scoping de pagos/órdenes que get_sales_summary_v2, '
  'agrupado por (área, producto).';

commit;
