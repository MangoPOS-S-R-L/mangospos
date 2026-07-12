-- =============================================================================
-- 20260710_0001 — Fix access check de get_products_by_production_area
-- =============================================================================
--
-- SÍNTOMA: el ticket de cierre de caja imprimía "Ventas por área de producción"
-- (totales) pero NUNCA el desglose de productos por área, en todos los negocios,
-- aun con el toggle cash_close_print_products_by_area activo y con datos.
--
-- CAUSA: la versión viva en prod de get_products_by_production_area quedó con
-- `where c.bid = _business_id` en el access check. Para cualquier caller
-- authenticated (la app) eso lanza 42703 "column c.bid does not exist"; la app
-- lo traga (best-effort) y omite la sección. En el SQL Editor con service_role
-- el chequeo se salta, por eso "funcionaba" al probarla a mano.
--
-- OJO ADICIONAL: current_user_business_ids() vivo devuelve SETOF uuid (desde
-- 20260708_0001 owner_all_branches_access), así que su única columna se llama
-- `current_user_business_ids` — un `from current_user_business_ids() c where
-- c.business_id = ...` SIN alias de columna (como está escrito en varias
-- migraciones del repo, p. ej. 20260616_0001) también rompe con 42703. Aquí
-- usamos `as c(business_id)`: el alias explícito de columna funciona igual si
-- la función devuelve SETOF uuid o TABLE(business_id uuid).
--
-- Resto del cuerpo: idéntico al vivo/repo (20260616_0001). Sin impacto fiscal.
-- =============================================================================

begin;

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
  -- Access check: service_role salta, authenticated debe pertenecer al negocio.
  -- `as c(business_id)` = alias EXPLÍCITO de columna (ver header).
  if auth.role() != 'service_role' then
    if not exists (
      select 1 from public.current_user_business_ids() as c(business_id)
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

commit;
