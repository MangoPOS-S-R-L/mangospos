-- 20260522_0003_paid_at_offline_sync.sql
-- Fase 3.2 — Soporte para preservar la fecha de venta original al sincronizar
-- pagos hechos offline.
--
-- Problema:
--   Cuando un cajero cobra offline, el payment se encola y se sincroniza
--   cuando vuelve la conexión. Hoy fn_process_payment_v3 usa now() en
--   payments.created_at, así que el payment queda registrado con la fecha
--   del SYNC, no de la venta original. Igual fiscal_documents.created_at
--   y order_checks.closed_at se asignan con now(). Esto descalibra:
--     - Reportes de ventas (la venta aparece en el día equivocado).
--     - NCF queda emitido con fecha que no coincide con la venta.
--     - Cierre de caja: ventas del turno offline pueden "saltar" al
--       siguiente turno al sincronizar.
--
-- Solución:
--   1. Agregar p_paid_at timestamptz default null al final de
--      fn_process_payment_v3 PRESERVANDO la firma vigente
--      (20260513_0007) con sus 13 parámetros previos. NULL → now()
--      (comportamiento online). Valor → ese timestamp para
--      payments.created_at, order_checks.closed_at,
--      cash_transactions.created_at.
--
--   2. Modificar issue_fiscal_document para que fiscal_documents.created_at
--      herede payment.created_at. Si payment vino con paid_at offline,
--      el fd queda fechado en la venta real, no en el sync.
--
-- Compat: signature anterior se DROPea y se recrea con un parámetro extra
-- opcional al final. Callers existentes siguen funcionando porque pasan
-- los mismos 13 args nombrados; el 14º queda con default null.

begin;

-- ---------------------------------------------------------------------------
-- 1. fn_process_payment_v3: misma firma 0007 + p_paid_at al final
-- ---------------------------------------------------------------------------
-- Importante: DROP de la firma vigente antes de CREATE OR REPLACE, porque
-- agregamos un parámetro nuevo (cambia la signatura aunque sea con default).
drop function if exists public.fn_process_payment_v3(
  uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text,
  boolean, smallint, boolean
);

create or replace function public.fn_process_payment_v3(
  p_order_id uuid,
  p_check_id uuid,
  p_payment_method_id text,
  p_amount numeric,
  p_reference text,
  p_customer_id uuid default null,
  p_customer_rnc text default null,
  p_cashier_session_id uuid default null,
  p_change_amount numeric default 0,
  p_requested_ncf_type text default null,
  p_close_order boolean default true,
  p_split_sequence smallint default 0,
  p_close_check boolean default true,
  -- Nuevo parámetro al final para no romper callers viejos. Cuando se
  -- sincroniza un payment offline, el cliente pasa el timestamp original
  -- de la venta. Para pagos online el parámetro queda null y se usa now().
  p_paid_at timestamptz default null
)
returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
  v_existing_payment public.payments;
  v_business_id uuid;
  v_table_session_id uuid;
  v_payment_method_id uuid;
  v_payment_method_code text;
  v_open_items_count bigint := 0;
  v_cash_in_drawer numeric := 0;
  v_requested_ncf_type public.ncf_type;
  v_check_is_closed boolean := false;
  v_order_closed_at timestamptz;
  v_order_status_ext public.order_status;
  v_check_customer_id uuid;
  v_check_customer_rnc text;
  v_check_requested_ncf_type public.ncf_type;
  v_effective_customer_id uuid;
  v_effective_customer_rnc text;
  v_payment_id uuid;
  v_effective_at timestamptz := coalesce(p_paid_at, now());
begin
  select o.session_id, o.closed_at, o.status_ext
    into v_table_session_id, v_order_closed_at, v_order_status_ext
  from public.orders o
  where o.id = p_order_id
  for update;

  if v_table_session_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  if p_check_id is not null then
    select c.is_closed, c.customer_id, c.customer_rnc, c.requested_ncf_type
      into v_check_is_closed, v_check_customer_id,
           v_check_customer_rnc, v_check_requested_ncf_type
    from public.order_checks c
    where c.id = p_check_id
    for update;

    if v_check_is_closed then
      select * into v_existing_payment
      from public.payments
      where order_id = p_order_id
        and check_id = p_check_id
        and status = 'completed'
      order by created_at desc
      limit 1;

      if v_existing_payment.id is not null then
        return v_existing_payment;
      end if;
      raise exception 'CHECK_ALREADY_CLOSED';
    end if;
  else
    if v_order_closed_at is not null
       or v_order_status_ext in ('paid'::public.order_status,
                                 'void'::public.order_status)
    then
      select * into v_existing_payment
      from public.payments
      where order_id = p_order_id
        and check_id is null
        and status = 'completed'
      order by created_at desc
      limit 1;

      if v_existing_payment.id is not null then
        return v_existing_payment;
      end if;
      raise exception 'ORDER_ALREADY_CLOSED';
    end if;
  end if;

  select ts.business_id
    into v_business_id
  from public.table_sessions ts
  where ts.id = v_table_session_id;

  if v_business_id is null then
    select z.business_id
      into v_business_id
    from public.table_sessions ts
    join public.dining_tables dt on dt.id = ts.table_id
    join public.zones z on z.id = dt.zone_id
    where ts.id = v_table_session_id
    limit 1;
  end if;

  if v_business_id is null then
    raise exception 'BUSINESS_NOT_RESOLVED';
  end if;

  if p_cashier_session_id is null then
    raise exception 'CASH_SESSION_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.cash_register_sessions cs
    where cs.id = p_cashier_session_id
      and cs.status = 'open'
      and cs.closed_at is null
  ) then
    raise exception 'CASH_SESSION_NOT_OPEN';
  end if;

  v_requested_ncf_type := coalesce(
    public.normalize_ncf_type(p_requested_ncf_type),
    v_check_requested_ncf_type
  );

  v_effective_customer_id := coalesce(p_customer_id, v_check_customer_id);
  v_effective_customer_rnc := coalesce(
    nullif(trim(coalesce(p_customer_rnc, '')), ''),
    nullif(trim(coalesce(v_check_customer_rnc, '')), '')
  );

  if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
    select pm.id, pm.code
      into v_payment_method_id, v_payment_method_code
    from public.payment_methods pm
    where pm.id = p_payment_method_id::uuid
      and pm.is_active = true
    limit 1;
  else
    select pm.id, pm.code
      into v_payment_method_id, v_payment_method_code
    from public.payment_methods pm
    where pm.business_id = v_business_id
      and pm.code = p_payment_method_id
      and pm.is_active = true
    limit 1;
  end if;

  if v_payment_method_id is null then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  insert into public.payments(
    business_id, order_id, check_id, payment_method_id,
    amount, reference, change_amount, status,
    processed_by, session_id, customer_id, customer_rnc,
    requested_ncf_type, split_sequence, created_at
  )
  values (
    v_business_id, p_order_id, p_check_id, v_payment_method_id,
    p_amount, p_reference, coalesce(p_change_amount, 0), 'completed',
    auth.uid(), p_cashier_session_id,
    v_effective_customer_id, v_effective_customer_rnc,
    v_requested_ncf_type, coalesce(p_split_sequence, 0),
    v_effective_at   -- ← p_paid_at si fue provisto, sino now()
  )
  returning id into v_payment_id;

  if p_check_id is not null then
    if p_close_check then
      update public.order_items
      set status = 'paid'
      where order_id = p_order_id
        and check_id = p_check_id
        and status <> 'void';

      update public.order_checks
      set is_closed = true,
          closed_at = v_effective_at   -- ← mismo timestamp
      where id = p_check_id;

      select count(*)
        into v_open_items_count
      from public.order_items
      where order_id = p_order_id
        and status not in ('paid', 'void');

      if v_open_items_count = 0 then
        perform public.fn_close_order_and_table(p_order_id, 'paid');
      end if;
    end if;
  else
    if p_close_order then
      update public.order_items
      set status = 'paid'
      where order_id = p_order_id
        and status <> 'void';

      perform public.fn_close_order_and_table(p_order_id, 'paid');
    end if;
  end if;

  if v_payment_method_code = 'cash' then
    v_cash_in_drawer := greatest(
      coalesce(p_amount, 0) - coalesce(p_change_amount, 0),
      0
    );

    if v_cash_in_drawer > 0 then
      insert into public.cash_transactions(
        session_id, amount, type, description, related_order_id, created_at
      )
      values (
        p_cashier_session_id, v_cash_in_drawer, 'sale',
        'Venta ' || left(p_order_id::text, 8), p_order_id,
        v_effective_at   -- ← mismo timestamp para coherencia de reportes
      );
    end if;
  end if;

  -- FIX 2026-05-13 (preservado): refrescar v_payment para que el RETURN
  -- incluya el fiscal_document_id seteado por los triggers de cierre.
  select * into v_payment
  from public.payments
  where id = v_payment_id;

  return v_payment;
end;
$$;

grant execute on function public.fn_process_payment_v3(
  uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text,
  boolean, smallint, boolean, timestamptz
) to anon, authenticated, service_role;

comment on function public.fn_process_payment_v3(
  uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text,
  boolean, smallint, boolean, timestamptz
) is
  'Procesa un pago. Soporta p_paid_at opcional para preservar la fecha '
  'original cuando se sincroniza un pago hecho offline. Si p_paid_at es '
  'NULL (caller online) usa now(). Si tiene valor (replay offline), lo '
  'usa para payments.created_at, order_checks.closed_at y '
  'cash_transactions.created_at.';

-- ---------------------------------------------------------------------------
-- 2. issue_fiscal_document hereda created_at del payment
-- ---------------------------------------------------------------------------
-- Antes el INSERT a fiscal_documents NO incluía created_at, así que tomaba
-- el default `now()`. Para que un payment offline mantenga su fecha real
-- en el fiscal_document al sincronizarse, ahora seteamos created_at
-- explícito = v_payment.created_at. Resto de la lógica (idempotencia,
-- prorrateo, ratio) intacta — solo añade una columna al INSERT.
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
  -- Idempotencia por payment_id (preservada de 20260512_0001).
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

  v_total := coalesce(v_payment.amount, 0);

  if v_base_total > 0 then
    v_ratio := v_total / v_base_total;
    v_subtotal    := round(v_base_subtotal * v_ratio, 2);
    v_itbis       := round(v_base_tax * v_ratio, 2);
    v_service_fee := round(v_base_service_fee * v_ratio, 2);
  else
    v_subtotal    := v_total;
    v_itbis       := 0;
    v_service_fee := 0;
  end if;

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
    is_electronic,
    created_at   -- ← nuevo: hereda fecha del payment para offline-sync
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
    left(v_ncf_type::text, 1) = 'E',
    coalesce(v_payment.created_at, now())
  )
  returning id into doc_id;

  update public.payments
  set fiscal_document_id = doc_id
  where id = _payment_id;

  return doc_id;
end;
$$;

comment on function public.issue_fiscal_document(uuid, uuid) is
  'Emite el fiscal_document con NCF para un payment. Hereda '
  'payment.created_at como fiscal_documents.created_at para que pagos '
  'offline sincronizados queden fechados en el momento real de la venta, '
  'no del sync. Resto de la lógica de prorrateo intacta.';

commit;
