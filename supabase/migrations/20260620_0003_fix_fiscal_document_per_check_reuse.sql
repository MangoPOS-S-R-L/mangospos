-- =============================================================================
-- Fix: split bill volvía a emitir UN solo comprobante para N sub-cuentas.
--
-- Bug raíz (regresión 2026-06-12): la versión viva de issue_fiscal_document
-- (de 20260612_0001_ncf_offline_emission) reintrodujo la idempotencia a nivel
-- ORDEN en el lookup inicial:
--
--     or (fd.order_id = _order_id and fd.status = 'active')
--
-- Eso hace que al cobrar la 2da/3ra sub-cuenta encuentre el fiscal_document de
-- la 1ra (misma orden, activo) y lo REUTILICE → el mismo NCF (y tipo) se repite
-- en las 3 cuentas. Es exactamente el bug que 20260511_0002 ya había arreglado.
-- Además, el insert NO seteaba fiscal_documents.check_id, por lo que el trigger
-- de recálculo (trg_fn_recompute_fd_on_payment_change → fn_recompute_fd_for_scope)
-- no podía scopear los totales por sub-cuenta y dejaba el total de la orden.
--
-- Fix (sin tocar nada más de la función viva):
--   A. El reuse a nivel orden queda ACOTADO a la misma sub-cuenta:
--        and fd.check_id is not distinct from v_check_id
--      Así cada check crea su propio fd (NULL = orden completa, p. ej. cobro
--      multi-método de toda la mesa, sigue reutilizando un único fd).
--   B. Se PUEBLA fiscal_documents.check_id con el check del pago en ambos
--      inserts (offline F4 y online). Esto, además de la idempotencia, hace
--      que el recálculo de totales scopee por check (subtotal/itbis/total del
--      check, no de la orden).
--
-- Basada EXACTAMENTE en la definición viva (20260612_0001). Solo cambian: el
-- fetch de v_check_id, el WHERE del lookup y la columna check_id en los inserts.
-- La rama F4 offline, el loop de colisión online y la resolución de cliente/RNC
-- quedan idénticos.
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

comment on function public.issue_fiscal_document(uuid, uuid) is
  'Emite el fiscal_document con NCF para un payment. Idempotencia: por '
  'payment_id, y reuso a nivel orden ACOTADO a la misma sub-cuenta '
  '(fd.check_id is not distinct from el check del pago) para no repetir el '
  'NCF en split bill. Puebla fiscal_documents.check_id (habilita totales por '
  'check en fn_recompute_fd_for_scope). Soporta offline_ncf (F4) y el loop de '
  'colisión online. Montos base del pedido; el trigger de recálculo los ajusta '
  'por scope al linkear el payment.';

commit;
