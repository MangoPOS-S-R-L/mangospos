-- =============================================================================
-- HARDENING: fn_process_payment_v3 ahora bloquea pagos duplicados sobre la
-- misma (order_id, check_id) tomando un FOR UPDATE atomico al entrar.
--
-- Bug observado (diag 2026-05-09): doble-tap o retry de red en el cliente
-- Dart (payment_split_viewmodel, payment_viewmodel, offline_pos_service)
-- generaba 2-3 rows en `payments` para la misma orden con spread de 2-13s.
-- El RPC v3 no tenia guard, asi que cada llamada exitosa insertaba payment
-- + el trigger trg_issue_fiscal generaba un fiscal_document para el primero
-- y trataba de attachar el doc al segundo. Resultado en historial: 2 rows
-- (una con NCF, otra como "Boleta/Ticket/Publico General") confundiendo al
-- cajero como si fueran 2 ventas.
--
-- Comportamiento nuevo:
--   1. SELECT ... FOR UPDATE sobre orders al entrar -> serializa concurrentes.
--   2. Si check_id presente y order_checks.is_closed=true:
--        -> retornar payment completed existente (idempotente para retries).
--        -> sin payment existente: lanzar CHECK_ALREADY_CLOSED.
--   3. Si check_id null y la orden ya esta cerrada (closed_at o status_ext
--      IN ('paid','void')):
--        -> retornar payment existente o lanzar ORDER_ALREADY_CLOSED.
--   4. Resto del cuerpo identico a la version 20260426_0001 (lo unico que
--      cambia es el bloque de validacion previo al INSERT).
--
-- Compat: signatura sin cambios. Errores nuevos son strings, faciles de
-- mappear en Dart.
-- =============================================================================

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
  -- Lock atomico de la orden. Cualquier llamada concurrente a esta misma
  -- order_id queda serializada hasta el commit. Sin esto, doble-tap o retry
  -- pasaba ambos checks de estado antes de que la primera llamada cerrara
  -- la orden, y se creaban 2 payments.
  -- ------------------------------------------------------------------------
  select o.session_id, o.closed_at, o.status_ext
    into v_table_session_id, v_order_closed_at, v_order_status_ext
  from public.orders o
  where o.id = p_order_id
  for update;

  if v_table_session_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  -- ------------------------------------------------------------------------
  -- Idempotency guard (con lock ya tomado).
  --   - Para split-checks: cada check se cierra al pagarse (is_closed=true).
  --     Otro check del mismo order todavia puede pagarse (no rechazamos la
  --     orden completa, solo el check ya cerrado).
  --   - Para pago full-order: la orden tiene closed_at y status_ext='paid'
  --     tras la primera llamada exitosa.
  -- En ambos casos, si encontramos el payment original lo retornamos para
  -- que el cliente reciba la respuesta correcta del retry y no vea error.
  -- ------------------------------------------------------------------------
  if p_check_id is not null then
    select c.is_closed
      into v_check_is_closed
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

  -- ------------------------------------------------------------------------
  -- Validaciones existentes (preservadas tal cual desde 20260426_0001).
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
