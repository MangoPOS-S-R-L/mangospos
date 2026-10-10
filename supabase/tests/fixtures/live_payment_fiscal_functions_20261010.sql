-- Definiciones VIVAS (pg_get_functiondef, 2026-10-10) del cobro con candado y de la emisión
-- del comprobante. Las usa supabase/tests/offline_payment_reconciliation_local_test.sh.

CREATE OR REPLACE FUNCTION public.issue_fiscal_document(_order_id uuid, _payment_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_business_id uuid;
  v_check_id uuid;
  v_scope record;
begin
  select coalesce(ts.business_id, z.business_id) into v_business_id
  from public.payments p
  join public.orders o on o.id = p.order_id
  left join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.zones z on z.id = dt.zone_id
  where p.id = _payment_id and p.order_id = _order_id
    and p.business_id = coalesce(ts.business_id, z.business_id);
  if v_business_id is null then
    raise exception 'NO_PAYMENTS_FOR_SCOPE';
  end if;
  select check_id into v_check_id from public.payments where id = _payment_id;
  select * into v_scope from public.fn_sales_note_policy_scope(_order_id, v_check_id);
  if not found or v_scope.business_id is distinct from v_business_id then
    raise exception 'SALES_DOCUMENT_BUSINESS_OUT_OF_SCOPE' using errcode = '42501';
  end if;
  if not (coalesce(auth.role(), '') = 'service_role'
          or (session_user in ('postgres', 'supabase_admin')
              and nullif(auth.role(), '') is null)
          or coalesce(public.is_member_of_business(v_business_id), false)) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(v_business_id::text || ':sales_note_number', 0));
  if exists (
    select 1 from public.payments p
    join public.sales_notes sn on sn.order_id = p.order_id
      and sn.check_id is not distinct from p.check_id and sn.status = 'active'
    where p.id = _payment_id
  ) then
    raise exception 'SALES_DOCUMENT_ALREADY_NOTED';
  end if;
  return public.issue_fiscal_document_unchecked(_order_id, _payment_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.issue_fiscal_document_unchecked(_order_id uuid, _payment_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_sequence_id uuid;
  v_attempts integer := 0;
  v_constraint_name text;
  v_check_id uuid;
begin
  -- check_id del pago actual: el reuse a nivel orden DEBE quedar acotado a la
  -- misma sub-cuenta (o ambos NULL para cobro de orden completa). Sin esto, en
  -- split bill el 2do/3er cobro reutilizaba el fd del 1ro → mismo NCF.
  select p.check_id
    into v_check_id
  from public.payments p
  where p.id = _payment_id;

  select fd.id
    into doc_id
  from public.fiscal_documents fd
  where (_payment_id is not null and fd.payment_id = _payment_id)
     or (
          fd.order_id = _order_id
          and fd.status = 'active'
          and fd.check_id is not distinct from v_check_id
        )
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

  -- ===== F4: rama OFFLINE (NCF pre-asignado por el Hub) =====
  if nullif(trim(coalesce(v_payment.offline_ncf, '')), '') is not null then
    ncf := trim(v_payment.offline_ncf);

    select s.id
      into v_sequence_id
    from public.ncf_sequences s
    where s.business_id = v_business_id
      and s.ncf_type = v_ncf_type
      and ncf like s.prefix || '%'
    order by s.created_at desc, s.id desc
    limit 1;

    if v_sequence_id is not null then
      update public.ncf_sequences s
         set current_number = greatest(
               s.current_number,
               case
                 when substring(ncf from char_length(s.prefix) + 1) ~ '^[0-9]+$'
                   then cast(substring(ncf from char_length(s.prefix) + 1) as bigint)
                 else s.current_number
               end
             )
       where s.id = v_sequence_id;
    end if;

    insert into public.fiscal_documents (
      business_id,
      order_id,
      check_id,
      payment_id,
      customer_id,
      ncf_type,
      ncf_number,
      ncf_sequence_id,
      customer_rnc,
      customer_name,
      subtotal,
      taxable_amount,
      itbis_amount,
      service_fee,
      total,
      is_electronic,
      offline_issued,
      created_at
    ) values (
      v_business_id,
      o.id,
      v_check_id,
      _payment_id,
      v_customer_id,
      v_ncf_type,
      ncf,
      v_sequence_id,
      v_customer_rnc,
      v_customer_name,
      coalesce(o.subtotal, 0),
      coalesce(o.subtotal, 0),
      coalesce(o.tax, 0),
      coalesce(o.service_fee, 0),
      coalesce(o.total, 0),
      left(v_ncf_type::text, 1) = 'E',
      true,
      coalesce(v_payment.created_at, now())
    )
    returning id into doc_id;

    update public.payments
    set fiscal_document_id = doc_id
    where id = _payment_id;

    return doc_id;
  end if;
  -- ===== fin F4; camino ONLINE intacto abajo =====

  loop
    begin
      select s.id
        into v_sequence_id
      from public.ncf_sequences s
      where s.business_id = v_business_id
        and s.ncf_type = v_ncf_type
        and s.is_active = true
        and s.current_number < s.range_end
        and (s.expiration_date is null or s.expiration_date > current_date)
      order by s.created_at desc, s.id desc
      limit 1;

      ncf := public.generate_ncf(v_business_id, v_ncf_type);

      insert into public.fiscal_documents (
        business_id,
        order_id,
        check_id,
        payment_id,
        customer_id,
        ncf_type,
        ncf_number,
        ncf_sequence_id,
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
        v_check_id,
        _payment_id,
        v_customer_id,
        v_ncf_type,
        ncf,
        v_sequence_id,
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
    exception
      when unique_violation then
        get stacked diagnostics v_constraint_name = CONSTRAINT_NAME;

        if v_constraint_name is distinct from 'fiscal_documents_business_id_ncf_number_key' then
          raise;
        end if;

        v_attempts := v_attempts + 1;

        if v_attempts >= 20 then
          raise exception 'Demasiadas colisiones de NCF. Revisa la tabla de facturas.'
            using errcode = 'P0001';
        end if;
    end;
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.trg_fn_issue_fd_on_order_close()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.closed_at is not null and old.closed_at is null
     and exists (select 1 from public.payments p
                 where p.order_id = new.id and p.check_id is null and p.status = 'completed') then
    perform public.fn_issue_sale_document(new.id, null,
      new.is_sales_note or exists (select 1 from public.order_checks c
                                  where c.order_id = new.id and c.position = 1 and c.is_sales_note));
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_payment_attempt_acquire(p_order_id uuid, p_attempt_id uuid, p_check_id uuid DEFAULT NULL::uuid, p_device_id text DEFAULT NULL::text, p_holder_label text DEFAULT NULL::text, p_ttl_seconds integer DEFAULT 120)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_closed_at timestamptz;
  v_status text;
  v_check_closed boolean;
  v_lease public.order_payment_attempts%rowtype;
  v_ttl interval := make_interval(secs => greatest(coalesce(p_ttl_seconds, 120), 15));
  v_paid numeric := 0;
  v_next_seq integer := 0;
  v_business_id uuid;
begin
  if p_order_id is null or p_attempt_id is null then
    raise exception 'ATTEMPT_ARGS_REQUIRED' using errcode = '22004';
  end if;

  -- Mismo candado de fila que fn_process_payment_v3: serializa con cualquier
  -- cobro en curso sobre esta orden.
  select o.closed_at, o.status_ext::text,
         coalesce(ts.business_id, z.business_id)
    into v_closed_at, v_status, v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.zones z on z.id = dt.zone_id
  where o.id = p_order_id
  for update of o;

  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;
  if v_business_id is null or not (
    coalesce(auth.role(), '') = 'service_role'
    or coalesce(public.is_member_of_business(v_business_id), false)
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;

  if v_closed_at is not null or v_status in ('paid', 'void') then
    return jsonb_build_object('acquired', false, 'reason', 'closed');
  end if;

  if p_check_id is not null then
    select coalesce(c.is_closed, false) into v_check_closed
    from public.order_checks c
    where c.id = p_check_id and c.order_id = p_order_id;
    if not found then
      raise exception 'CHECK_OUT_OF_SCOPE' using errcode = '42501';
    end if;
    if coalesce(v_check_closed, false) then
      return jsonb_build_object('acquired', false, 'reason', 'closed');
    end if;
  end if;

  select * into v_lease
  from public.order_payment_attempts
  where order_id = p_order_id;

  if found
     and v_lease.attempt_id <> p_attempt_id
     and v_lease.expires_at > now() then
    return jsonb_build_object(
      'acquired', false,
      'reason', 'held',
      'holder_label', v_lease.holder_label,
      'device_id', v_lease.device_id,
      'check_id', v_lease.check_id,
      'started_at', v_lease.started_at,
      'expires_at', v_lease.expires_at
    );
  end if;

  insert into public.order_payment_attempts (
    order_id, attempt_id, check_id, device_id, holder_label, started_at, expires_at
  ) values (
    p_order_id, p_attempt_id, p_check_id, p_device_id, p_holder_label, now(), now() + v_ttl
  )
  on conflict (order_id) do update
    set attempt_id = excluded.attempt_id,
        check_id = excluded.check_id,
        device_id = excluded.device_id,
        holder_label = excluded.holder_label,
        started_at = case
          when order_payment_attempts.attempt_id = excluded.attempt_id
            then order_payment_attempts.started_at
          else now()
        end,
        expires_at = excluded.expires_at;

  -- Lo ya cobrado en ESTE alcance (orden completa o esa subcuenta) por OTROS
  -- intentos mientras la cuenta sigue abierta: un cobro que quedó a medias.
  select coalesce(sum(p.amount - coalesce(p.change_amount, 0)), 0)
    into v_paid
  from public.payments p
  where p.order_id = p_order_id
    and p.status = 'completed'
    and p.check_id is not distinct from p_check_id
    and p.client_attempt_id is distinct from p_attempt_id;

  -- El índice único de pagos es (orden, subcuenta, método, split_sequence): un
  -- intento nuevo arranca después del último usado para no chocar con abonos
  -- previos del mismo método.
  select coalesce(max(p.split_sequence) + 1, 0)
    into v_next_seq
  from public.payments p
  where p.order_id = p_order_id
    and p.status = 'completed'
    and p.check_id is not distinct from p_check_id;

  return jsonb_build_object(
    'acquired', true,
    'paid_by_others', v_paid,
    'next_split_sequence', v_next_seq,
    'expires_at', now() + v_ttl
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_payment_attempt_release(p_order_id uuid, p_attempt_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_business_id uuid;
begin
  select coalesce(ts.business_id, z.business_id) into v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.zones z on z.id = dt.zone_id
  where o.id = p_order_id;
  if v_business_id is null or not (
    coalesce(auth.role(), '') = 'service_role'
    or coalesce(public.is_member_of_business(v_business_id), false)
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  delete from public.order_payment_attempts
  where order_id = p_order_id and attempt_id = p_attempt_id;
  return found;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_process_payment_v3_attempt(p_attempt_id uuid, p_order_id uuid, p_check_id uuid, p_payment_method_id text, p_amount numeric, p_reference text, p_customer_id uuid DEFAULT NULL::uuid, p_customer_rnc text DEFAULT NULL::text, p_cashier_session_id uuid DEFAULT NULL::uuid, p_change_amount numeric DEFAULT 0, p_requested_ncf_type text DEFAULT NULL::text, p_close_order boolean DEFAULT true, p_split_sequence smallint DEFAULT 0, p_close_check boolean DEFAULT true, p_paid_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ttl_seconds integer DEFAULT 120, p_offline_ncf text DEFAULT NULL::text)
 RETURNS payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lease public.order_payment_attempts%rowtype;
  v_payment public.payments;
  v_ttl interval := make_interval(secs => greatest(coalesce(p_ttl_seconds, 120), 15));
  v_business_id uuid;
begin
  if p_attempt_id is null then
    raise exception 'ATTEMPT_ID_REQUIRED' using errcode = '22004';
  end if;

  select coalesce(ts.business_id, z.business_id) into v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.zones z on z.id = dt.zone_id
  where o.id = p_order_id
  for update of o;
  if v_business_id is null or not (
    coalesce(auth.role(), '') = 'service_role'
    or coalesce(public.is_member_of_business(v_business_id), false)
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  if p_check_id is not null and not exists (
    select 1 from public.order_checks c
    where c.id = p_check_id and c.order_id = p_order_id
  ) then
    raise exception 'CHECK_OUT_OF_SCOPE' using errcode = '42501';
  end if;

  select * into v_lease
  from public.order_payment_attempts
  where order_id = p_order_id;

  if found
     and v_lease.attempt_id <> p_attempt_id
     and v_lease.expires_at > now() then
    raise exception 'PAYMENT_LOCKED_BY_OTHER_DEVICE'
      using errcode = 'MP420',
            detail = coalesce(v_lease.holder_label, ''),
            hint = coalesce(v_lease.device_id, '');
  end if;
  if not found or v_lease.attempt_id is distinct from p_attempt_id
     or v_lease.expires_at <= now()
     or v_lease.check_id is distinct from p_check_id then
    raise exception 'PAYMENT_ATTEMPT_EXPIRED' using errcode = 'MP421';
  end if;

  -- El trigger de payments lee este valor: marca el pago con su intento y deja
  -- pasar a quien tiene el candado. Local a la transacción.
  perform set_config('mangopos.payment_attempt_id', p_attempt_id::text, true);

  update public.order_payment_attempts
     set expires_at = now() + v_ttl
   where order_id = p_order_id and attempt_id = p_attempt_id;

  v_payment := public.fn_process_payment_v3(
    p_order_id => p_order_id,
    p_check_id => p_check_id,
    p_payment_method_id => p_payment_method_id,
    p_amount => p_amount,
    p_reference => p_reference,
    p_customer_id => p_customer_id,
    p_customer_rnc => p_customer_rnc,
    p_cashier_session_id => p_cashier_session_id,
    p_change_amount => p_change_amount,
    p_requested_ncf_type => p_requested_ncf_type,
    p_close_order => p_close_order,
    p_split_sequence => p_split_sequence,
    p_close_check => p_close_check,
    p_paid_at => p_paid_at,
    p_offline_ncf => p_offline_ncf
  );

  -- El abono que cierra la cuenta suelta el candado; los intermedios lo
  -- conservan (ya renovado arriba).
  if (p_check_id is null and p_close_order)
     or (p_check_id is not null and p_close_check) then
    delete from public.order_payment_attempts
    where order_id = p_order_id and attempt_id = p_attempt_id;
  end if;

  return v_payment;
end;
$function$;
