-- =============================================================================
-- ROLLBACK de 20260620_0003_fix_fiscal_document_per_check_reuse.sql
--
-- Restaura issue_fiscal_document a la versión previa (la de 20260612_0001),
-- que reusa el fiscal_document a nivel orden y NO setea check_id.
-- ⚠️ Esto REINTRODUCE el bug de split bill (mismo NCF para N sub-cuentas).
-- Solo usar si el fix forward causa un problema mayor.
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
as $function$
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

  select * into o from public.orders where id = _order_id;
  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  select p.* into v_payment from public.payments p where p.id = _payment_id;

  v_business_id := v_payment.business_id;
  if v_business_id is null then
    select ts.business_id into v_business_id
    from public.table_sessions ts where ts.id = o.session_id;
  end if;
  if v_business_id is null then
    raise exception 'No se pudo resolver business_id para order %', _order_id;
  end if;

  select * into fs from public.fiscal_settings where business_id = v_business_id;

  v_ncf_type := coalesce(
    v_payment.requested_ncf_type,
    fs.default_ncf_type,
    case when coalesce(fs.ecf_enabled, false) then 'E32'::public.ncf_type
         else 'B02'::public.ncf_type end
  );

  select c.id,
         nullif(trim(coalesce(c.tax_id, '')), ''),
         nullif(trim(coalesce(c.name, '')), '')
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
    (select nullif(trim(coalesce(ts.customer_name, '')), '')
       from public.table_sessions ts where ts.id = o.session_id limit 1),
    v_master_customer_name,
    'Consumidor Final'
  );

  if nullif(trim(coalesce(v_payment.offline_ncf, '')), '') is not null then
    ncf := trim(v_payment.offline_ncf);

    select s.id into v_sequence_id
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
               case when substring(ncf from char_length(s.prefix) + 1) ~ '^[0-9]+$'
                      then cast(substring(ncf from char_length(s.prefix) + 1) as bigint)
                    else s.current_number end)
       where s.id = v_sequence_id;
    end if;

    insert into public.fiscal_documents (
      business_id, order_id, payment_id, customer_id, ncf_type, ncf_number,
      ncf_sequence_id, customer_rnc, customer_name, subtotal, taxable_amount,
      itbis_amount, service_fee, total, is_electronic, offline_issued, created_at
    ) values (
      v_business_id, o.id, _payment_id, v_customer_id, v_ncf_type, ncf,
      v_sequence_id, v_customer_rnc, v_customer_name,
      coalesce(o.subtotal, 0), coalesce(o.subtotal, 0), coalesce(o.tax, 0),
      coalesce(o.service_fee, 0), coalesce(o.total, 0),
      left(v_ncf_type::text, 1) = 'E', true, coalesce(v_payment.created_at, now())
    )
    returning id into doc_id;

    update public.payments set fiscal_document_id = doc_id where id = _payment_id;
    return doc_id;
  end if;

  loop
    begin
      select s.id into v_sequence_id
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
        business_id, order_id, payment_id, customer_id, ncf_type, ncf_number,
        ncf_sequence_id, customer_rnc, customer_name, subtotal, taxable_amount,
        itbis_amount, service_fee, total, is_electronic
      ) values (
        v_business_id, o.id, _payment_id, v_customer_id, v_ncf_type, ncf,
        v_sequence_id, v_customer_rnc, v_customer_name,
        coalesce(o.subtotal, 0), coalesce(o.subtotal, 0), coalesce(o.tax, 0),
        coalesce(o.service_fee, 0), coalesce(o.total, 0),
        left(v_ncf_type::text, 1) = 'E'
      )
      returning id into doc_id;

      update public.payments set fiscal_document_id = doc_id where id = _payment_id;
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

commit;
