-- =============================================================================
-- Refuerza el guard de fn_process_payment_v3 cambiando SELECT FOR UPDATE por
-- pg_advisory_xact_lock como mecanismo principal de serializacion.
--
-- Contexto:
--   Migration 20260509_0001 puso un SELECT FOR UPDATE sobre orders al inicio
--   del RPC. Verificamos el cuerpo deployed y tiene el lock. Pero el mismo
--   dia se crearon 4 duplicados que el lock no bloqueo. Hipotesis: en
--   ambiente Supabase con PgBouncer en transaction-pooling + PostgREST, el
--   row-level lock (FOR UPDATE) tiene casos edge donde no serializa como
--   en pg vanilla.
--
--   pg_advisory_xact_lock NO depende de row visibility ni MVCC. Es un lock
--   numerico per-transaction administrado por el server. Dos transacciones
--   con el mismo key se serializan obligatoriamente. El patron ya esta
--   probado en `fn_transfer_table_session` (20260508_0007).
--
-- Cambio:
--   - Al entrar al RPC, antes que cualquier otra cosa: PERFORM
--     pg_advisory_xact_lock(hashtextextended(p_order_id::text, 0)).
--   - SELECT (sin FOR UPDATE) para leer session_id, closed_at, status_ext.
--     Ya no hace falta el row lock — el advisory lock garantiza la
--     serializacion. SELECT plain es mas barato y menos afectado por
--     pooling.
--   - El resto del cuerpo (validaciones, INSERT, fn_close_order_and_table,
--     cash_transactions) se mantiene identico.
--
-- Compat: signatura idem. Comportamiento externo idem (mismo guard
-- ORDER_ALREADY_CLOSED / CHECK_ALREADY_CLOSED, mismo retry behavior).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_process_payment_v3(
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
begin
  -- ------------------------------------------------------------------------
  -- Lock advisory transaccional. Dos llamadas concurrentes para la misma
  -- order_id se serializan obligatoriamente. No depende de row visibility
  -- ni MVCC, es robusto bajo PgBouncer transaction-pooling. El lock se
  -- libera automaticamente al COMMIT/ROLLBACK de la transaccion.
  -- ------------------------------------------------------------------------
  perform pg_advisory_xact_lock(hashtextextended(p_order_id::text, 0));

  -- Leer estado actual de la orden (post-lock). Sin FOR UPDATE porque ya
  -- estamos serializados por el advisory lock.
  select o.session_id, o.closed_at, o.status_ext
    into v_table_session_id, v_order_closed_at, v_order_status_ext
  from public.orders o
  where o.id = p_order_id;

  if v_table_session_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  -- ------------------------------------------------------------------------
  -- Idempotency guard (con advisory lock ya tomado). Mismo comportamiento
  -- que 20260509_0001: si la orden/check ya esta cerrada, retorna el
  -- payment existente o lanza ORDER_ALREADY_CLOSED / CHECK_ALREADY_CLOSED.
  -- ------------------------------------------------------------------------
  if p_check_id is not null then
    -- Tambien advisory lock por check_id para que pagos a checks distintos
    -- de la misma orden no compitan entre si (paralelos seguros).
    perform pg_advisory_xact_lock(hashtextextended(p_check_id::text, 1));

    select c.is_closed
      into v_check_is_closed
    from public.order_checks c
    where c.id = p_check_id;

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

  -- ------------------------------------------------------------------------
  -- Validaciones existentes (preservadas tal cual desde 20260426_0001 +
  -- 20260509_0001).
  -- ------------------------------------------------------------------------
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
