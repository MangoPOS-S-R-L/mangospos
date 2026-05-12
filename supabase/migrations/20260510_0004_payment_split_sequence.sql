-- =============================================================================
-- Fix: permitir splits intencionales del mismo método sobre una orden
--
-- Caso de uso (2026-05-12): tres clientes comparten una mesa con total 1200.
-- Cada uno paga 400 de su parte con un billete de 1000. El cajero necesita
-- registrar tres entradas separadas de "Efectivo 1000" para reflejar quién
-- entregó qué — no un único pago consolidado de 3000.
--
-- Problema con la migration 20260510_0003:
--   El unique index `payments_unique_completed_per_check_method`
--   (order_id, check_id, payment_method_id) bloquea N pagos legítimos del
--   mismo método porque no distingue "tres clientes con cash" de
--   "doble-tap accidental".
--
-- Solución:
--
--   A. Agregar columna `split_sequence smallint default 0 not null` a
--      `payments`. Cada split intencional del mismo método incrementa este
--      contador (0, 1, 2, ...). Filas históricas se quedan en 0 (no hay
--      conflicto porque sólo había una fila por grupo).
--
--   B. Reemplazar el unique index para incluir `split_sequence` en la clave.
--      Ahora bloquea sólo (order, check, method, sequence) duplicados —
--      double-tap del mismo split sigue protegido (el cliente reusa la misma
--      sequence en el retry), pero N splits intencionales coexisten.
--
--   C. Agregar `p_split_sequence smallint default 0` al RPC.
--      El cliente Dart pasa el índice de la transacción dentro del split.
--      Para pagos single-method o flujos legacy, el default 0 mantiene el
--      comportamiento previo.
--
-- Compatibilidad:
--   - Pagos single-method existentes: una sola fila, sequence=0. ✓
--   - Splits via checks: cada check tiene su propio fd y sus payments con
--     sequence=0 (el sequence se aísla dentro del check). ✓
--   - Splits full-order legítimos: sequence 0, 1, 2... cada uno fila propia. ✓
--   - Double-tap del mismo split: mismo sequence → 23505 unique_violation →
--     fallback del Dart lo recupera. ✓
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- A. Columna split_sequence
-- ---------------------------------------------------------------------------

alter table public.payments
  add column if not exists split_sequence smallint not null default 0;

comment on column public.payments.split_sequence is
  'Indice 0-based del split dentro del set de payments de la misma '
  '(order_id, check_id, payment_method_id). Distingue N pagos legitimos '
  'del mismo metodo (ej: tres clientes pagando con cash separadamente) de '
  'duplicates accidentales (doble-tap reusa la sequence y choca contra el '
  'unique index).';

-- ---------------------------------------------------------------------------
-- B. Reemplazar el unique index
-- ---------------------------------------------------------------------------

drop index if exists public.payments_unique_completed_per_check_method;

create unique index if not exists payments_unique_completed_per_check_method_seq
on public.payments (
  order_id,
  coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid),
  payment_method_id,
  split_sequence
)
where status = 'completed';

comment on index public.payments_unique_completed_per_check_method_seq is
  'Prohibe 2 payments completed identicos en (order, check, method, split_sequence). '
  'Permite N pagos legitimos del mismo metodo en una orden cuando cada uno '
  'tiene su propio split_sequence (cliente A pago cash #0, cliente B pago '
  'cash #1, etc). Bloquea double-tap (cliente Dart reusa la sequence en el '
  'retry).';

-- ---------------------------------------------------------------------------
-- C. Recrear fn_process_payment_v3 con p_split_sequence
-- ---------------------------------------------------------------------------
-- Drop + recreate por la misma razón que en 20260510_0003: signatura cambia.

drop function if exists public.fn_process_payment_v3(
  uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text, boolean
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
begin
  -- Lock atomico de la orden.
  select o.session_id, o.closed_at, o.status_ext
    into v_table_session_id, v_order_closed_at, v_order_status_ext
  from public.orders o
  where o.id = p_order_id
  for update;

  if v_table_session_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  -- Idempotency guard.
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

  -- Validaciones preservadas.
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
    business_id, order_id, check_id, payment_method_id,
    amount, reference, change_amount, status,
    processed_by, session_id, customer_id, customer_rnc,
    requested_ncf_type, split_sequence, created_at
  )
  values (
    v_business_id, p_order_id, p_check_id, v_payment_method_id,
    p_amount, p_reference, coalesce(p_change_amount, 0), 'completed',
    auth.uid(), p_cashier_session_id, p_customer_id, p_customer_rnc,
    v_requested_ncf_type, coalesce(p_split_sequence, 0), now()
  )
  returning * into v_payment;

  -- Cierre / marcado de items (igual que 20260510_0003).
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
