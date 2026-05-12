-- =============================================================================
-- Asignación temprana de cliente y tipo de comprobante por sub-cuenta.
--
-- Hasta hoy, customer_id y requested_ncf_type vivían solo en `payments`.
-- Eso obliga al cajero a configurar cliente/NCF en el momento del cobro
-- de cada sub-cuenta, lo que en split bill multiplica el error.
--
-- Toast/Square (y este rediseño) modelan esto a nivel sub-cuenta:
-- "este check es del cliente A con NCF E32", "este otro del cliente B con B02".
-- Al cobrar, el payment hereda esos datos automáticamente.
--
-- Cambios:
--   1) ALTER TABLE order_checks: agregar customer_id, customer_rnc,
--      requested_ncf_type (todos nullable, default NULL).
--   2) Nuevo RPC fn_set_check_customer_and_ncf(check_id, customer_id,
--      customer_rnc, requested_ncf_type) — sirve para que la UI persista
--      la asignación temprana sin tocar la tabla directamente (más seguro
--      que un PATCH RLS-controlado y centraliza validaciones).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) Columnas nuevas en order_checks
-- ---------------------------------------------------------------------------

alter table public.order_checks
  add column if not exists customer_id uuid references public.customers(id) on delete set null;

alter table public.order_checks
  add column if not exists customer_rnc text;

alter table public.order_checks
  add column if not exists requested_ncf_type public.ncf_type;

comment on column public.order_checks.customer_id is
  'Cliente asignado a esta sub-cuenta. Al cobrar el check, el payment '
  'hereda este customer_id si el cajero no lo sobrescribe en el modal '
  'de pago. NULL = sin cliente asignado, cae al de la sesión de mesa o '
  'a "Consumidor Final".';

comment on column public.order_checks.customer_rnc is
  'RNC del cliente para esta sub-cuenta (cuando el cliente no está dado '
  'de alta en `customers` pero el cajero ingresa el RNC manualmente). '
  'Hereda al payment al cobrar.';

comment on column public.order_checks.requested_ncf_type is
  'Tipo de comprobante para esta sub-cuenta (B01/B02/E31/E32...). '
  'Hereda al payment al cobrar. NULL = usar default_ncf_type del business.';

-- ---------------------------------------------------------------------------
-- 2) RPC para setear estos campos desde el cliente
-- ---------------------------------------------------------------------------

create or replace function public.fn_set_check_customer_and_ncf(
  p_check_id uuid,
  p_customer_id uuid default null,
  p_customer_rnc text default null,
  p_requested_ncf_type text default null
)
returns public.order_checks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_check public.order_checks%rowtype;
  v_ncf_type public.ncf_type;
begin
  if p_check_id is null then
    raise exception 'CHECK_ID_REQUIRED';
  end if;

  -- Validar que el check exista y esté abierto.
  select * into v_check
  from public.order_checks
  where id = p_check_id
  for update;

  if not found then
    raise exception 'CHECK_NOT_FOUND';
  end if;

  if v_check.is_closed then
    raise exception 'CHECK_ALREADY_CLOSED';
  end if;

  -- Normalizar tipo NCF (acepta texto vacío como NULL).
  v_ncf_type := public.normalize_ncf_type(p_requested_ncf_type);

  update public.order_checks
  set
    customer_id        = p_customer_id,
    customer_rnc       = nullif(trim(coalesce(p_customer_rnc, '')), ''),
    requested_ncf_type = v_ncf_type
  where id = p_check_id
  returning * into v_check;

  return v_check;
end;
$$;

grant execute on function public.fn_set_check_customer_and_ncf(
  uuid, uuid, text, text
) to authenticated, service_role;

comment on function public.fn_set_check_customer_and_ncf(uuid, uuid, text, text) is
  'Asignación temprana de cliente y tipo de comprobante a una sub-cuenta. '
  'La UI llama esto cuando el cajero configura quién paga el check antes '
  'del cobro. Al cobrar, el payment hereda estos valores si el modal de '
  'pago no los sobrescribe.';

-- ---------------------------------------------------------------------------
-- 3) Extender fn_process_payment_v3 para usar el customer/NCF del check si
--    el caller no los pasa explícitamente.
--
--    Lógica de fallback (de mayor a menor prioridad):
--       1. Parámetros del RPC (lo que pasa el caller explícitamente).
--       2. Campos del order_check correspondiente.
--       3. (en issue_fiscal_document) Customer de la sesión de mesa.
--       4. Default del business.
-- ---------------------------------------------------------------------------

drop function if exists public.fn_process_payment_v3(
  uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text, boolean, smallint
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
  p_split_sequence smallint default 0
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

  -- Resolver tipo de comprobante: param explícito > check > default.
  v_requested_ncf_type := coalesce(
    public.normalize_ncf_type(p_requested_ncf_type),
    v_check_requested_ncf_type
  );

  -- Resolver cliente: param explícito > check.
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
    v_requested_ncf_type, coalesce(p_split_sequence, 0), now()
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
        session_id, amount, type, description, related_order_id
      )
      values (
        p_cashier_session_id, v_cash_in_drawer, 'sale',
        'Venta ' || left(p_order_id::text, 8), p_order_id
      );
    end if;
  end if;

  return v_payment;
end;
$$;

grant execute on function public.fn_process_payment_v3(
  uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text,
  boolean, smallint
) to anon, authenticated, service_role;

commit;
