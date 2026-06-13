-- =============================================================================
-- 20260612_0001 — Emisión de NCF offline (F4, Etapa 1: contrato DB)
-- =============================================================================
--
-- Habilita que un pago hecho SIN conexión llegue al servidor con su NCF YA
-- asignado (por el Hub Local / allocator en la LAN) y se registre con ESE
-- número, en vez de generar uno nuevo. Pieza de RECONCILIACIÓN del modelo (b)
-- — una sola serie autorizada por DGII, repartida secuencial por el
-- coordinador local mientras no hay internet. Solo PAPEL (B0x) offline.
--
-- ⚠️ BASE = DEFINICIONES VIVAS DE LA BD (no las del repo).
-- Verificado 2026-06-12 con pg_get_functiondef: esta base NO tiene la
-- migración 20260522_0003 aplicada. Por eso:
--   - `fn_process_payment_v3` vive en su versión de 13 args (sin p_paid_at) y
--     usa now() para created_at.
--   - `issue_fiscal_document` vive en su versión con loop de colisión, montos
--     del PEDIDO (no prorrateados) y `ncf_sequence_id`.
-- Esta migración reproduce ESAS versiones vivas y solo añade:
--   1. `p_paid_at`  → necesario porque el replay offline ya lo envía; sin él
--      el sync de pagos offline FALLA hoy. Preserva la fecha real de venta.
--   2. `p_offline_ncf` → el NCF pre-asignado offline.
--   3. Rama offline en `issue_fiscal_document` que usa ese NCF.
-- NO cambia montos, prorrateo, loop de colisión ni `ncf_sequence_id`.
--
-- Inerte hasta encender `kOfflineNcfEnabled` (cliente): sin la flag ningún
-- pago trae offline_ncf y la rama nueva nunca corre. El online queda idéntico.
--
-- ⚠️ FISCAL: emite con un número asignado fuera del servidor. Encender SOLO
-- tras prueba controlada en una caja contra DGII. Ver docs/PRD_OFFLINE_F4_NCF.md.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columnas de soporte (aditivas, idempotentes)
-- ---------------------------------------------------------------------------
alter table public.payments
  add column if not exists offline_ncf text;

comment on column public.payments.offline_ncf is
  'NCF asignado localmente (Hub/allocator) cuando el pago se cobró sin '
  'conexión. NULL = pago online (el servidor genera el NCF). En el sync, '
  'issue_fiscal_document usa este número en vez de generate_ncf. F4.';

alter table public.fiscal_documents
  add column if not exists offline_issued boolean not null default false;

comment on column public.fiscal_documents.offline_issued is
  'True si el comprobante se emitió offline (NCF asignado localmente) y se '
  'concilió al reconectar. Default false.';

-- ---------------------------------------------------------------------------
-- 2. issue_fiscal_document — versión VIVA + rama offline
-- ---------------------------------------------------------------------------
-- Reproduce la función viva (loop de colisión, montos del pedido,
-- ncf_sequence_id, idempotencia legacy). ÚNICO añadido: una rama al inicio
-- que, si el payment trae offline_ncf, usa ese número, avanza current_number
-- y marca offline_issued=true. El camino ONLINE (el loop) queda intacto.
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
  -- Si el payment trae offline_ncf, NO se genera número nuevo: se usa ese,
  -- se avanza current_number de su serie (emparejada por prefijo) y se marca
  -- offline_issued. Sin retry-loop: un offline_ncf duplicado es un error real
  -- (lo atrapa el UNIQUE business_id+ncf_number). Hereda created_at del payment
  -- (fechado en la venta real, no en el sync). Montos = del pedido, igual que
  -- el camino online de abajo.
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
  'Emite el fiscal_document con NCF para un payment. Si payment.offline_ncf '
  'viene seteado (cobro offline reconciliado), usa ESE número, avanza '
  'current_number y marca offline_issued=true (sin generate_ncf). El camino '
  'online conserva el loop de colisión y los montos del pedido.';

-- ---------------------------------------------------------------------------
-- 3. fn_process_payment_v3 — versión VIVA (13 args) + p_paid_at + p_offline_ncf
-- ---------------------------------------------------------------------------
-- Se DROPea la firma viva de 13 args y se recrea con 2 parámetros nuevos al
-- final. p_paid_at preserva la fecha real de la venta offline (lo exige el
-- replay actual); p_offline_ncf transporta el NCF pre-asignado. Ambos null →
-- comportamiento online idéntico (created_at = now()).
--
-- (Queda viva la firma legacy de 10 args, inofensiva/no usada por la app. Se
-- puede limpiar aparte si se desea.)
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
  p_paid_at timestamptz default null,
  p_offline_ncf text default null
)
returns public.payments
language plpgsql
security definer
set search_path = public
as $function$
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
    requested_ncf_type, split_sequence, created_at,
    offline_ncf
  )
  values (
    v_business_id, p_order_id, p_check_id, v_payment_method_id,
    p_amount, p_reference, coalesce(p_change_amount, 0), 'completed',
    auth.uid(), p_cashier_session_id,
    v_effective_customer_id, v_effective_customer_rnc,
    v_requested_ncf_type, coalesce(p_split_sequence, 0), v_effective_at,
    nullif(trim(coalesce(p_offline_ncf, '')), '')
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
          closed_at = v_effective_at
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
        'Venta ' || left(p_order_id::text, 8), p_order_id, v_effective_at
      );
    end if;
  end if;

  -- FIX 2026-05-13: refrescar v_payment para que el RETURN incluya el
  -- fiscal_document_id seteado por los triggers de cierre.
  select * into v_payment
  from public.payments
  where id = v_payment_id;

  return v_payment;
end;
$function$;

grant execute on function public.fn_process_payment_v3(
  uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text,
  boolean, smallint, boolean, timestamptz, text
) to anon, authenticated, service_role;

comment on function public.fn_process_payment_v3(
  uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text,
  boolean, smallint, boolean, timestamptz, text
) is
  'Procesa un pago. p_paid_at preserva la fecha real de un cobro offline al '
  'sincronizar (created_at de payment, order_checks.closed_at y '
  'cash_transactions). p_offline_ncf (F4): NCF asignado localmente; '
  'issue_fiscal_document lo usa en vez de generar uno nuevo. Ambos null = '
  'comportamiento online idéntico.';

commit;
