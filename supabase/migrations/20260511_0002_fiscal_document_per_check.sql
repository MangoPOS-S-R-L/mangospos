-- =============================================================================
-- Fix: split bill genera UN solo comprobante para N pagos.
--
-- Bug raíz (2026-05-11):
--   issue_fiscal_document(_order_id, _payment_id) hacía idempotencia doble:
--     1) por payment_id (correcto: evita duplicar fd si la función se llama
--        dos veces para el mismo pago).
--     2) por (order_id + status='active') (INCORRECTO para split bill: el
--        primer cobro creaba un fd y los siguientes cobros de la misma
--        orden lo reutilizaban en vez de crear el suyo propio).
--
--   Resultado pre-fix: una mesa con 3 sub-cuentas pagadas separadamente
--   generaba 1 NCF (el del primer cobro) y los siguientes pagos quedaban
--   asociados a ese mismo fd. En el historial se veía una sola factura
--   con el total de la orden completa, no tres con el total de cada check.
--
-- Fix:
--   A. La idempotencia queda SOLO por payment_id. Cada pago tiene su propio
--      comprobante. Si un pago no tiene fd aún → se crea. Si ya tiene →
--      se retorna sin duplicar.
--
--   B. Los totales del fd ahora reflejan el CHECK específico cuando el
--      payment tiene check_id (split bill). Lectura:
--        - payment.check_id IS NULL → totales de la orden (comportamiento
--          legacy para pagos full-order).
--        - payment.check_id IS NOT NULL → totales del check (subtotal,
--          discounts, tax, service_fee, total leídos de order_checks).
--
--   C. El cliente y RNC siguen viniendo del payment (ya soportado) — cada
--      pago puede tener su propio cliente sin tocar nada más.
--
-- Compat:
--   - Pagos legacy ya emitidos: fds existentes intactos.
--   - Pagos single-method full-order: mismo flujo que antes.
--   - Idempotencia post-fix: si por algún reintento del trigger se llama
--     issue_fiscal_document dos veces con el mismo payment_id, retorna el
--     mismo fd sin duplicar (lookup por payment_id).
-- =============================================================================

begin;

create or replace function public.issue_fiscal_document(
  _order_id uuid,
  _payment_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
  fs record;
  v_payment public.payments%rowtype;
  v_check record;
  ncf text;
  doc_id uuid;
  v_business_id uuid;
  v_ncf_type public.ncf_type;
  v_customer_id uuid;
  v_customer_rnc text;
  v_customer_name text;
  v_master_customer_id uuid;
  v_master_customer_rnc text;
  v_master_customer_name text;
  v_subtotal numeric(12,2);
  v_taxable numeric(12,2);
  v_itbis numeric(12,2);
  v_service_fee numeric(12,2);
  v_total numeric(12,2);
begin
  -- Idempotencia: ÚNICAMENTE por payment_id. Si este pago ya tiene fd,
  -- retornarlo. Nunca reutilizar el fd de otro pago aunque sea de la misma
  -- orden — eso rompía split bill.
  select fd.id
    into doc_id
  from public.fiscal_documents fd
  where fd.payment_id = _payment_id
  order by fd.created_at desc
  limit 1;

  if doc_id is not null then
    return doc_id;
  end if;

  select *
    into o
  from public.orders
  where id = _order_id;

  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  select p.*
    into v_payment
  from public.payments p
  where p.id = _payment_id;

  v_business_id := v_payment.business_id;

  if v_business_id is null then
    select ts.business_id
      into v_business_id
    from public.table_sessions ts
    where ts.id = o.session_id;
  end if;

  if v_business_id is null then
    raise exception 'No se pudo resolver business_id para order %', _order_id;
  end if;

  select *
    into fs
  from public.fiscal_settings
  where business_id = v_business_id;

  v_ncf_type := coalesce(
    v_payment.requested_ncf_type,
    fs.default_ncf_type,
    case
      when coalesce(fs.ecf_enabled, false) then 'E32'::public.ncf_type
      else 'B02'::public.ncf_type
    end
  );

  select
    c.id,
    nullif(trim(coalesce(c.tax_id, '')), '') as tax_id,
    nullif(trim(coalesce(c.name, '')), '') as name
    into v_master_customer_id, v_master_customer_rnc, v_master_customer_name
  from public.table_sessions ts
  left join public.customers c
    on c.id = coalesce(v_payment.customer_id, ts.customer_id)
  where ts.id = o.session_id
  limit 1;

  v_customer_id := coalesce(v_payment.customer_id, v_master_customer_id);
  v_customer_rnc := coalesce(
    nullif(trim(coalesce(v_payment.customer_rnc, '')), ''),
    v_master_customer_rnc
  );
  v_customer_name := coalesce(
    (
      select nullif(trim(coalesce(ts.customer_name, '')), '')
      from public.table_sessions ts
      where ts.id = o.session_id
      limit 1
    ),
    v_master_customer_name,
    'Consumidor Final'
  );

  -- Totales del fd: si el payment es de un check específico (split bill),
  -- usar los totales del check. Si es full-order, usar los de la orden.
  if v_payment.check_id is not null then
    select
      coalesce(oc.subtotal, 0)    as subtotal,
      coalesce(oc.discounts, 0)   as discounts,
      coalesce(oc.tax, 0)         as tax,
      coalesce(oc.service_fee, 0) as service_fee,
      coalesce(oc.total, 0)       as total
      into v_check
    from public.order_checks oc
    where oc.id = v_payment.check_id;

    v_subtotal    := v_check.subtotal;
    v_taxable     := v_check.subtotal;
    v_itbis       := v_check.tax;
    v_service_fee := v_check.service_fee;
    v_total       := v_check.total;
  else
    v_subtotal    := coalesce(o.subtotal, 0);
    v_taxable     := coalesce(o.subtotal, 0);
    v_itbis       := coalesce(o.tax, 0);
    v_service_fee := coalesce(o.service_fee, 0);
    v_total       := coalesce(o.total, 0);
  end if;

  ncf := public.generate_ncf(v_business_id, v_ncf_type);

  insert into public.fiscal_documents (
    business_id,
    order_id,
    payment_id,
    customer_id,
    ncf_type,
    ncf_number,
    customer_rnc,
    customer_name,
    subtotal,
    taxable_amount,
    itbis_amount,
    service_fee,
    total,
    is_electronic
  ) values (
    v_business_id,
    o.id,
    _payment_id,
    v_customer_id,
    v_ncf_type,
    ncf,
    v_customer_rnc,
    v_customer_name,
    v_subtotal,
    v_taxable,
    v_itbis,
    v_service_fee,
    v_total,
    left(v_ncf_type::text, 1) = 'E'
  )
  returning id into doc_id;

  update public.payments
  set fiscal_document_id = doc_id
  where id = _payment_id;

  return doc_id;
end;
$$;

commit;
