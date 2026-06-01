-- =============================================================================
-- get_fiscal_summary_bundle — trae en UN solo viaje todo lo que el reporte de
-- impuestos (getFiscalDocumentsSummary en Dart) necesita: fiscal_documents +
-- taxes + order_items + orders del rango.
--
-- PROBLEMA: el reporte de impuestos hacía 7-15 round-trips (fiscal_documents,
-- taxes, y order_items/orders en lotes de 150) → lento vs el reporte de ventas
-- que usa 1 RPC. Este bundle colapsa esos viajes a 1.
--
-- IMPORTANTE: la AGREGACIÓN sigue 100% en Dart (split ITBIS/LEY por config,
-- base = total - itbis - ley, guarda de comp). Este RPC SOLO mueve el fetch al
-- servidor; NO cambia ningún número. Por construcción devuelve exactamente las
-- mismas filas que las queries que reemplaza:
--   - documents: todos los fiscal_documents del rango (cualquier status).
--   - taxes: config de impuestos del negocio.
--   - order_items / orders: solo de las órdenes de documentos ACTIVOS
--     (igual que el Dart, que arma orderIds desde activeRows).
-- =============================================================================

create or replace function public.get_fiscal_summary_bundle(
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
  -- Access check: service_role salta; authenticated valida pertenencia.
  if auth.role() != 'service_role' then
    if not exists (
      select 1 from current_user_business_ids() c
      where c.business_id = _business_id
    ) then
      raise exception 'access denied' using errcode = '42501';
    end if;
  end if;

  with docs as (
    select fd.id, fd.order_id, fd.payment_id, fd.customer_id, fd.ncf_type,
           fd.ncf_number, fd.customer_rnc, fd.customer_name, fd.subtotal,
           fd.taxable_amount, fd.itbis_amount, fd.service_fee, fd.total,
           fd.status, fd.issued_at
    from fiscal_documents fd
    where fd.business_id = _business_id
      and fd.issued_at >= _from
      and fd.issued_at <  _to
  ),
  active_orders as (
    select distinct order_id
    from docs
    where status = 'active' and order_id is not null
  )
  select jsonb_build_object(
    'documents', coalesce(
      (select jsonb_agg(to_jsonb(d) order by d.issued_at) from docs d),
      '[]'::jsonb),
    'taxes', coalesce(
      (select jsonb_agg(jsonb_build_object(
         'id', t.id, 'name', t.name, 'rate', t.rate,
         'is_active', t.is_active, 'is_service_fee', t.is_service_fee))
       from taxes t where t.business_id = _business_id),
      '[]'::jsonb),
    'order_items', coalesce(
      (select jsonb_agg(jsonb_build_object(
         'order_id', oi.order_id, 'tax', oi.tax, 'tax_rate', oi.tax_rate,
         'subtotal', oi.subtotal, 'total', oi.total, 'qty', oi.qty,
         'quantity', oi.quantity, 'status', oi.status))
       from order_items oi
       where oi.order_id in (select order_id from active_orders)),
      '[]'::jsonb),
    'orders', coalesce(
      (select jsonb_agg(jsonb_build_object(
         'id', o.id, 'service_fee', o.service_fee, 'status_ext', o.status_ext))
       from orders o
       where o.id in (select order_id from active_orders)),
      '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

grant execute on function public.get_fiscal_summary_bundle(uuid, timestamp with time zone, timestamp with time zone)
  to authenticated, service_role;

comment on function public.get_fiscal_summary_bundle(uuid, timestamp with time zone, timestamp with time zone) is
  'Bundle de un solo viaje para el reporte de impuestos: fiscal_documents + '
  'taxes + order_items + orders del rango. La agregación sigue en Dart; este '
  'RPC solo reduce 7-15 round-trips a 1 sin cambiar ningún número.';
