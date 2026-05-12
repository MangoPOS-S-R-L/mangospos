-- =============================================================================
-- Fix: el comprobante debe reflejar el monto que el cliente PAGÓ, no el
-- recálculo de BD.
--
-- Bug raíz (2026-05-12):
--   Reporte del usuario: cobré una cuenta por RD$412.50 y el comprobante
--   salió por RD$450.74. Diferencia de 38.24 (~9.27%).
--
--   Causa: hay divergencia estructural entre cómo el frontend calcula el
--   total de un check y cómo lo hace `calculate_check_totals`:
--
--     - Frontend `summarizeOrderPricing` (order_pricing_utils.dart:473-478):
--       para items con tax_mode='inclusive' (el precio del menú ya
--       incluye ITBIS y service_fee), ancla el total al gross-catálogo.
--       NO suma service_fee aparte porque ya está bakeado en el subtotal.
--
--     - Backend `calculate_check_totals`: SIEMPRE recalcula
--       service_fee = subtotal * sf_rate / 100 y lo suma al total. No
--       distingue inclusive de exclusive, así que duplica el service_fee
--       cuando los items son inclusive.
--
--   Resultado: oc.total > UI display total cuando hay items inclusive.
--   Antes del fix de 20260511_0002 esto estaba enmascarado (NCF usaba
--   orders.total con el mismo drift). Con un NCF por check, el cajero
--   ahora ve cobros distintos a las facturas.
--
-- Fix:
--   El comprobante refleja `payment.amount` (lo que el cliente realmente
--   pagó), no `oc.total` o `o.total`. Los subtotales (subtotal/tax/
--   service_fee) se prorratean con el ratio `payment.amount / base`
--   donde `base` es el total del check (o de la orden si no hay check).
--
--   Caso normal (payment cubre todo el check): ratio = 1, prorrateo =
--   identidad. fd.total = payment.amount = oc.total cuando no hay drift.
--
--   Caso del bug (UI mostró 412.50, BD calculó 450.74): payment.amount
--   = 412.50 (el cajero cobró lo que la UI dijo), fd.total = 412.50.
--   El cliente paga = la factura. ✓
--
--   Caso de split por métodos (cash 200 + tarjeta 212.50 sobre check
--   de 412.50): cada payment genera su propio NCF por su monto. Suma
--   de NCFs = 412.50. Cada NCF es válido fiscalmente por sí solo.
--
-- Compat:
--   - fds emitidos antes de esta migration: intactos.
--   - Payments existentes con fd asociado: idempotency por payment_id
--     intacta — re-llamar issue_fiscal_document retorna el fd existente
--     sin cambios.
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
  v_base_subtotal numeric(12,2);
  v_base_tax numeric(12,2);
  v_base_service_fee numeric(12,2);
  v_base_total numeric(12,2);
  v_ratio numeric(12,8);
  v_subtotal numeric(12,2);
  v_taxable numeric(12,2);
  v_itbis numeric(12,2);
  v_service_fee numeric(12,2);
  v_total numeric(12,2);
begin
  -- Idempotencia por payment_id (la misma del fix anterior). Si este pago
  -- ya tiene fd, retornarlo sin tocar nada.
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

  -- Obtener "base" para prorrateo: totales del check si aplica, o de la
  -- orden si es full-order. Estos son los valores recalculados por BD que
  -- pueden tener drift respecto al UI.
  if v_payment.check_id is not null then
    select
      coalesce(oc.subtotal, 0),
      coalesce(oc.tax, 0),
      coalesce(oc.service_fee, 0),
      coalesce(oc.total, 0)
      into v_base_subtotal, v_base_tax, v_base_service_fee, v_base_total
    from public.order_checks oc
    where oc.id = v_payment.check_id;
  else
    v_base_subtotal    := coalesce(o.subtotal, 0);
    v_base_tax         := coalesce(o.tax, 0);
    v_base_service_fee := coalesce(o.service_fee, 0);
    v_base_total       := coalesce(o.total, 0);
  end if;

  -- Prorrateo: si payment.amount == base, ratio=1, fd refleja la base
  -- limpiamente. Si difieren (caso del bug 412.50 vs 450.74), prorrateamos
  -- subtotal/tax/service_fee para que la SUMA cuadre con payment.amount.
  --
  -- v_total siempre es v_payment.amount: lo que el cliente pagó. Esto es
  -- el invariante que protege contra cualquier drift de cálculo.
  v_total := coalesce(v_payment.amount, 0);

  if v_base_total > 0 then
    v_ratio := v_total / v_base_total;
    v_subtotal    := round(v_base_subtotal * v_ratio, 2);
    v_itbis       := round(v_base_tax * v_ratio, 2);
    v_service_fee := round(v_base_service_fee * v_ratio, 2);
  else
    -- Edge case: la base es 0 (puede pasar en órdenes muy raras). El fd
    -- refleja el payment.amount como subtotal sin desglose.
    v_subtotal    := v_total;
    v_itbis       := 0;
    v_service_fee := 0;
  end if;

  -- Ajuste final: residuo de redondeo se mete en subtotal para que la
  -- suma cuadre exactamente con payment.amount (regla DGII: total =
  -- subtotal + itbis + service_fee - discounts).
  declare
    v_sum numeric(12,2);
    v_residual numeric(12,2);
  begin
    v_sum := v_subtotal + v_itbis + v_service_fee;
    v_residual := v_total - v_sum;
    if abs(v_residual) > 0 and abs(v_residual) < 1 then
      v_subtotal := v_subtotal + v_residual;
    end if;
  end;

  v_taxable := v_subtotal;

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
