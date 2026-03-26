begin;

alter table public.payments
  add column if not exists requested_ncf_type public.ncf_type;

create or replace function public.normalize_ncf_type(p_raw text)
returns public.ncf_type
language plpgsql
immutable
as $$
declare
  v_value text := upper(trim(coalesce(p_raw, '')));
begin
  case v_value
    when '' then return null;
    when '01' then return 'B01'::public.ncf_type;
    when 'B01' then return 'B01'::public.ncf_type;
    when '02' then return 'B02'::public.ncf_type;
    when 'B02' then return 'B02'::public.ncf_type;
    when '14' then return 'B14'::public.ncf_type;
    when 'B14' then return 'B14'::public.ncf_type;
    when '15' then return 'B15'::public.ncf_type;
    when 'B15' then return 'B15'::public.ncf_type;
    when '31' then return 'E31'::public.ncf_type;
    when 'E31' then return 'E31'::public.ncf_type;
    when '32' then return 'E32'::public.ncf_type;
    when 'E32' then return 'E32'::public.ncf_type;
    else
      raise exception 'INVALID_NCF_TYPE';
  end case;
end;
$$;

drop function if exists public.fn_process_payment_v3(
  uuid,
  uuid,
  text,
  numeric,
  text,
  uuid,
  text,
  uuid,
  numeric
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
  p_requested_ncf_type text default null
)
returns public.payments
language plpgsql
security definer
set search_path=public
as $$
declare
  v_payment public.payments;
  v_business_id uuid;
  v_table_session_id uuid;
  v_payment_method_id uuid;
  v_payment_method_code text;
  v_open_items_count bigint := 0;
  v_cash_in_drawer numeric := 0;
  v_requested_ncf_type public.ncf_type;
begin
  select o.session_id
    into v_table_session_id
  from public.orders o
  where o.id = p_order_id;

  if v_table_session_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  select ts.business_id
    into v_business_id
  from public.table_sessions ts
  where ts.id = v_table_session_id;

  if v_business_id is null then
    select bid
      into v_business_id
    from public.current_user_business_ids() as bid
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

  v_requested_ncf_type := public.normalize_ncf_type(p_requested_ncf_type);

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
    business_id,
    order_id,
    check_id,
    payment_method_id,
    amount,
    reference,
    change_amount,
    status,
    processed_by,
    session_id,
    customer_id,
    customer_rnc,
    requested_ncf_type,
    created_at
  )
  values (
    v_business_id,
    p_order_id,
    p_check_id,
    v_payment_method_id,
    p_amount,
    p_reference,
    coalesce(p_change_amount, 0),
    'completed',
    auth.uid(),
    p_cashier_session_id,
    p_customer_id,
    p_customer_rnc,
    v_requested_ncf_type,
    now()
  )
  returning * into v_payment;

  if p_check_id is not null then
    update public.order_items
    set status = 'paid'
    where order_id = p_order_id
      and check_id = p_check_id
      and status <> 'void';

    update public.order_checks
    set is_closed = true,
        closed_at = now()
    where id = p_check_id;

    select count(*)
      into v_open_items_count
    from public.order_items
    where order_id = p_order_id
      and status not in ('paid', 'void');

    if v_open_items_count = 0 then
      perform public.fn_close_order_and_table(p_order_id, 'paid');
    end if;
  else
    update public.order_items
    set status = 'paid'
    where order_id = p_order_id
      and status <> 'void';

    perform public.fn_close_order_and_table(p_order_id, 'paid');
  end if;

  if v_payment_method_code = 'cash' then
    v_cash_in_drawer := greatest(
      coalesce(p_amount, 0) - coalesce(p_change_amount, 0),
      0
    );

    if v_cash_in_drawer > 0 then
      insert into public.cash_transactions(
        session_id,
        amount,
        type,
        description,
        related_order_id
      )
      values (
        p_cashier_session_id,
        v_cash_in_drawer,
        'sale',
        'Venta ' || left(p_order_id::text, 8),
        p_order_id
      );
    end if;
  end if;

  return v_payment;
end;
$$;

grant all on function public.fn_process_payment_v3(
  uuid,
  uuid,
  text,
  numeric,
  text,
  uuid,
  text,
  uuid,
  numeric,
  text
) to anon;

grant all on function public.fn_process_payment_v3(
  uuid,
  uuid,
  text,
  numeric,
  text,
  uuid,
  text,
  uuid,
  numeric,
  text
) to authenticated;

grant all on function public.fn_process_payment_v3(
  uuid,
  uuid,
  text,
  numeric,
  text,
  uuid,
  text,
  uuid,
  numeric,
  text
) to service_role;

create or replace function public.issue_fiscal_document(_order_id uuid, _payment_id uuid)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  o record;
  fs record;
  v_payment public.payments%rowtype;
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
begin
  select fd.id
    into doc_id
  from public.fiscal_documents fd
  where (_payment_id is not null and fd.payment_id = _payment_id)
     or (fd.order_id = _order_id and fd.status = 'active')
  order by fd.created_at desc
  limit 1;

  if doc_id is not null then
    update public.payments
    set fiscal_document_id = doc_id
    where id = _payment_id
      and fiscal_document_id is distinct from doc_id;

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
    coalesce(o.subtotal, 0),
    coalesce(o.subtotal, 0),
    coalesce(o.tax, 0),
    coalesce(o.service_fee, 0),
    coalesce(o.total, 0),
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
