-- =============================================================================
-- 20261010_0008 — T07: conciliación de cobros hechos sin red
-- =============================================================================
--
-- PROBLEMA. El cobro hecho sin red sube después con fn_process_payment_v3:
--   - Sin identidad propia: si la respuesta se pierde, el reintento se reconoce
--     solo por (orden, subcuenta, método, secuencia, monto). Dos equipos que
--     cobraron la misma cuenta con el mismo método y monto se confunden.
--   - Si su caja ya cerró, la v3 lo rechaza (CASH_SESSION_NOT_OPEN) y la cola
--     lo reintenta hasta rendirse con un error genérico: nadie decide qué hacer
--     con ese dinero.
--   - Si la cuenta creció mientras tanto (ORDER_PAYMENT_UNDERCOVERED) o ya la
--     cobró otro equipo, igual: error genérico.
--   - Nadie revisa después que pagos, saldo, subcuentas y comprobantes cuadren.
--
-- QUÉ HACE.
--   1. offline_payment_receipts: un recibo durable por cobro (p_payment_key,
--      estable: sale del id de la acción de la cola). Guarda lo pedido, la caja
--      y la fecha originales, el resultado y la conciliación. Un reintento
--      devuelve el mismo resultado sin cobrar dos veces.
--   2. fn_replay_offline_payment: sube el cobro con la v3 VIVA (mismos
--      disparadores: comprobante, crédito, abonos, candado de cobro), con su
--      caja y su fecha. Si no puede aplicarse tal cual, NO lo aplica ni lo
--      mueve: deja el recibo «por resolver» con el motivo:
--        cash_session_closed / cash_session_unknown / cash_session_missing,
--        paid_at_in_future (más de 1 h adelante: reloj del equipo),
--        order_already_paid / order_voided / payment_slot_taken / order_changed.
--      Con 20261010_0020 (cuentas en revisión), si lo tardío de esa cuenta
--      quedó en una cuenta en revisión, el detalle la nombra.
--      La fecha no se compara con la apertura de la caja: una caja abierta sin
--      red nace en el servidor al sincronizar, después de sus cobros.
--   3. fn_resolve_offline_payment: la decisión explícita (dueño, admin o
--      gerente): post_to_open_session (a una caja abierta del negocio, con su
--      fecha original y la nota de la caja cerrada), apply_as_partial (como
--      abono, la cuenta queda abierta), apply_anyway (fecha adelantada),
--      apply_to_review_order (a la cuenta en revisión que nació de esa cuenta;
--      nunca sola) o acknowledge (no se aplica; el recibo queda como
--      constancia).
--   El recibo guarda la caja local de origen (p_origin_session_ref) y si se
--   adoptó una caja ya abierta en el servidor: nada cambia de caja sin
--   constancia.
--   4. fn_order_money_state: la foto de conciliación de una cuenta (saldo,
--      sobrepago, subcuentas, comprobante). Se guarda en cada recibo;
--      fn_offline_payment_issues lista lo pendiente y lo que no cuadra.
--
-- No modifica fn_process_payment_v3 ni el cierre de caja: los llama tal cual.
-- La app nueva usa esta entrada al sincronizar; sin la migración (PGRST202)
-- sigue con la v3 de siempre.
--
-- IDEMPOTENTE. Reversa: 20261010_0008_offline_payment_reconciliation_ROLLBACK.sql
-- Prueba local: supabase/tests/offline_payment_reconciliation_local_test.sh
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Recibos
-- ---------------------------------------------------------------------------
create table if not exists public.offline_payment_receipts (
  payment_key        uuid primary key,
  business_id        uuid not null,
  order_id           uuid not null,
  check_id           uuid,
  -- Lo que pidió el equipo (para resolver después sin perder nada).
  request            jsonb not null,
  cash_session_id    uuid,
  paid_at            timestamptz,
  amount             numeric not null,
  change_amount      numeric not null default 0,
  payment_method     text not null,
  split_sequence     smallint not null default 0,
  device_id          text,
  status             text not null,
  reason             text,
  detail             jsonb,
  payment_id         uuid,
  -- Caja donde quedó (distinta de la original solo por decisión explícita).
  applied_session_id uuid,
  money              jsonb,
  resolution         text,
  resolution_note    text,
  resolved_by        uuid,
  resolved_at        timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint offline_payment_receipts_status_check
    check (status in ('applied', 'needs_resolution', 'resolved', 'acknowledged'))
);
create index if not exists idx_offline_payment_receipts_business_status
  on public.offline_payment_receipts (business_id, status);
create index if not exists idx_offline_payment_receipts_order
  on public.offline_payment_receipts (order_id);
alter table public.offline_payment_receipts enable row level security;
revoke all on public.offline_payment_receipts from anon, authenticated;

comment on table public.offline_payment_receipts is
  'T07 (20261010_0008): un recibo por cobro hecho sin red. Identidad estable, '
  'caja y fecha originales, resultado y conciliación. Solo se escribe por '
  'fn_replay_offline_payment / fn_resolve_offline_payment.';

-- ---------------------------------------------------------------------------
-- 2. Foto de conciliación de una cuenta
-- ---------------------------------------------------------------------------
create or replace function public.fn_order_money_state_internal(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_order     public.orders%rowtype;
  v_expected  numeric := 0;
  v_open_due  numeric := 0;
  v_paid      numeric := 0;
  v_tolerance numeric;
  v_flags     text[] := '{}';
  v_checks    jsonb := '[]'::jsonb;
  v_check     record;
  v_has_doc   boolean := false;
begin
  select * into v_order from public.orders where id = p_order_id;
  if not found then
    return null;
  end if;

  select coalesce(sum(oi.subtotal + oi.tax - coalesce(oi.discounts, 0)), 0)
    into v_expected
    from public.order_items oi
   where oi.order_id = p_order_id and oi.status::text <> 'void';
  v_expected := v_expected + coalesce(v_order.delivery_fee, 0);

  select coalesce(sum(oi.subtotal + oi.tax - coalesce(oi.discounts, 0)), 0)
    into v_open_due
    from public.order_items oi
   where oi.order_id = p_order_id and oi.status::text not in ('paid', 'void');

  select coalesce(sum(p.amount - coalesce(p.change_amount, 0)), 0)
    into v_paid
    from public.payments p
   where p.order_id = p_order_id and p.status = 'completed';

  v_tolerance := greatest(1.0, v_expected * 0.01);

  if v_order.status_ext::text = 'paid' and v_paid < v_expected - v_tolerance then
    v_flags := array_append(v_flags, 'balance_due');
  end if;
  if v_paid > v_expected + v_tolerance then
    v_flags := array_append(v_flags, 'overpaid');
  end if;
  if v_order.closed_at is null and v_expected > 0
     and v_open_due <= v_tolerance and v_paid >= v_expected - v_tolerance then
    v_flags := array_append(v_flags, 'paid_but_open');
  end if;

  for v_check in
    select c.id, c.position, c.is_closed,
           coalesce((select sum(oi.subtotal + oi.tax - coalesce(oi.discounts, 0))
                       from public.order_items oi
                      where oi.check_id = c.id and oi.status::text <> 'void'), 0) as due,
           coalesce((select sum(p.amount - coalesce(p.change_amount, 0))
                       from public.payments p
                      where p.check_id = c.id and p.status = 'completed'), 0) as paid
      from public.order_checks c
     where c.order_id = p_order_id
     order by c.position
  loop
    v_checks := v_checks || jsonb_build_object(
      'check_id', v_check.id, 'position', v_check.position,
      'is_closed', v_check.is_closed, 'due', v_check.due, 'paid', v_check.paid);
    if v_check.is_closed and v_check.position > 1
       and v_check.paid < v_check.due - greatest(1.0, v_check.due * 0.01) then
      v_flags := array_append(v_flags, 'check_closed_unpaid');
    end if;
  end loop;

  if v_order.status_ext::text = 'paid' and v_paid > 0 then
    select exists (
             select 1 from public.fiscal_documents fd
              where fd.order_id = p_order_id and fd.status = 'active')
        or exists (
             select 1 from public.sales_notes sn
              where sn.order_id = p_order_id and sn.status = 'active')
      into v_has_doc;
    if not v_has_doc then
      v_flags := array_append(v_flags, 'document_missing');
    end if;
  end if;

  return jsonb_build_object(
    'order_id', p_order_id,
    'status', v_order.status_ext::text,
    'closed_at', v_order.closed_at,
    'expected', round(v_expected, 2),
    'open_due', round(v_open_due, 2),
    'paid', round(v_paid, 2),
    'balance', round(v_expected - v_paid, 2),
    'checks', v_checks,
    'flags', to_jsonb(v_flags));
end;
$$;

create or replace function public.fn_order_money_state(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_business uuid;
begin
  select coalesce(ts.business_id, z.business_id) into v_business
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where o.id = p_order_id;
  if v_business is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;
  if not (
    coalesce(auth.role(), '') = 'service_role'
    or (session_user in ('postgres', 'supabase_admin') and nullif(auth.role(), '') is null)
    or coalesce(public.is_member_of_business(v_business), false)
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  return public.fn_order_money_state_internal(p_order_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Aplicar un cobro (uso interno: la reproducción y la resolución)
-- ---------------------------------------------------------------------------
-- Devuelve el pago aplicado o null con p_reason/p_detail llenos.
create or replace function public.fn_apply_offline_payment_locked(
  p_request    jsonb,
  p_session_id uuid,
  p_close_flags boolean,
  out o_payment public.payments,
  out o_reason text,
  out o_detail jsonb
)
language plpgsql
security definer
set search_path = public
as $$
begin
  o_payment := public.fn_process_payment_v3(
    p_order_id => (p_request ->> 'order_id')::uuid,
    p_check_id => nullif(p_request ->> 'check_id', '')::uuid,
    p_payment_method_id => p_request ->> 'payment_method_id',
    p_amount => (p_request ->> 'amount')::numeric,
    p_reference => p_request ->> 'reference',
    p_customer_id => nullif(p_request ->> 'customer_id', '')::uuid,
    p_customer_rnc => p_request ->> 'customer_rnc',
    p_cashier_session_id => p_session_id,
    p_change_amount => coalesce((p_request ->> 'change_amount')::numeric, 0),
    p_requested_ncf_type => p_request ->> 'requested_ncf_type',
    p_close_order => p_close_flags and coalesce((p_request ->> 'close_order')::boolean, true),
    p_split_sequence => coalesce((p_request ->> 'split_sequence')::smallint, 0::smallint),
    p_close_check => p_close_flags and coalesce((p_request ->> 'close_check')::boolean, true),
    p_paid_at => (p_request ->> 'paid_at')::timestamptz,
    p_offline_ncf => nullif(p_request ->> 'offline_ncf', '')
  );
exception when others then
  if sqlerrm like 'ORDER_PAYMENT_UNDERCOVERED%' then
    o_payment := null;
    o_reason := 'order_changed';
    o_detail := jsonb_build_object('message', sqlerrm);
  else
    raise;
  end if;
end;
$$;

-- El cobro devuelto es EL pedido (no otro de la misma cuenta).
create or replace function public.fn_offline_payment_matches(
  p_payment public.payments,
  p_request jsonb,
  p_session_id uuid
)
returns boolean
language sql
stable
set search_path = public
as $$
  select p_payment.id is not null
     and p_payment.status = 'completed'
     and p_payment.order_id = (p_request ->> 'order_id')::uuid
     and p_payment.check_id is not distinct from nullif(p_request ->> 'check_id', '')::uuid
     and p_payment.split_sequence = coalesce((p_request ->> 'split_sequence')::smallint, 0::smallint)
     and abs(p_payment.amount - (p_request ->> 'amount')::numeric) < 0.005
     and abs(coalesce(p_payment.change_amount, 0)
             - coalesce((p_request ->> 'change_amount')::numeric, 0)) < 0.005
     and p_payment.session_id is not distinct from p_session_id
$$;

-- ---------------------------------------------------------------------------
-- 4. Reproducir un cobro hecho sin red
-- ---------------------------------------------------------------------------
create or replace function public.fn_replay_offline_payment(
  p_payment_key        uuid,
  p_order_id           uuid,
  p_check_id           uuid,
  p_payment_method_id  text,
  p_amount             numeric,
  p_reference          text default null,
  p_customer_id        uuid default null,
  p_customer_rnc       text default null,
  p_cashier_session_id uuid default null,
  p_change_amount      numeric default 0,
  p_requested_ncf_type text default null,
  p_close_order        boolean default true,
  p_split_sequence     smallint default 0,
  p_close_check        boolean default true,
  p_paid_at            timestamptz default null,
  p_offline_ncf        text default null,
  p_device_id          text default null,
  p_origin_session_ref text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business   uuid;
  v_order      public.orders%rowtype;
  v_receipt    public.offline_payment_receipts%rowtype;
  v_session    record;
  v_request    jsonb;
  v_existing   public.payments;
  v_payment    public.payments;
  v_reason     text;
  v_detail     jsonb;
  v_closed     boolean;
  v_method_id  uuid;
  v_money      jsonb;
  v_result     jsonb;
  v_apply      record;
  v_review     uuid;
begin
  if p_payment_key is null or p_order_id is null then
    raise exception 'PAYMENT_KEY_REQUIRED' using errcode = '22004';
  end if;

  select coalesce(ts.business_id, z.business_id) into v_business
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where o.id = p_order_id;
  if v_business is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;
  if not (
    coalesce(auth.role(), '') = 'service_role'
    or (session_user in ('postgres', 'supabase_admin') and nullif(auth.role(), '') is null)
    or coalesce(public.is_member_of_business(v_business), false)
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;

  -- El candado de la cuenta (el del cobro y las ediciones).
  select * into v_order from public.orders where id = p_order_id for update;

  -- Reintento: el mismo resultado, sin cobrar otra vez.
  select * into v_receipt
    from public.offline_payment_receipts
   where payment_key = p_payment_key
   for update;
  if found then
    if v_receipt.order_id <> p_order_id then
      raise exception 'PAYMENT_KEY_CONFLICT' using errcode = 'MP430';
    end if;
    if v_receipt.status <> 'needs_resolution' then
      return jsonb_build_object(
        'status', v_receipt.status, 'reason', v_receipt.reason,
        'detail', v_receipt.detail, 'payment_id', v_receipt.payment_id,
        'applied_session_id', v_receipt.applied_session_id,
        'money', public.fn_order_money_state_internal(p_order_id),
        'replayed', true);
    end if;
  end if;

  v_request := jsonb_build_object(
    'order_id', p_order_id, 'check_id', p_check_id,
    'payment_method_id', p_payment_method_id, 'amount', p_amount,
    'reference', p_reference, 'customer_id', p_customer_id,
    'customer_rnc', p_customer_rnc, 'cashier_session_id', p_cashier_session_id,
    'change_amount', coalesce(p_change_amount, 0),
    'requested_ncf_type', p_requested_ncf_type,
    'close_order', coalesce(p_close_order, true),
    'split_sequence', coalesce(p_split_sequence, 0),
    'close_check', coalesce(p_close_check, true),
    'paid_at', coalesce(p_paid_at, now()),
    'offline_ncf', p_offline_ncf,
    'origin_session_ref', p_origin_session_ref);

  -- a) La caja original: existe, es del negocio y sigue abierta.
  if p_cashier_session_id is null then
    v_reason := 'cash_session_missing';
  else
    select cs.id, cs.status, cs.opened_at, cs.closed_at, cr.business_id, cr.name
      into v_session
      from public.cash_register_sessions cs
      join public.cash_registers cr on cr.id = cs.cash_register_id
     where cs.id = p_cashier_session_id;
    if not found or v_session.business_id is distinct from v_business then
      v_reason := 'cash_session_unknown';
    elsif v_session.status <> 'open' or v_session.closed_at is not null then
      v_reason := 'cash_session_closed';
      v_detail := jsonb_build_object(
        'cash_session_id', v_session.id, 'register', v_session.name,
        'opened_at', v_session.opened_at, 'closed_at', v_session.closed_at);
    elsif p_paid_at is not null and p_paid_at > now() + interval '1 hour' then
      v_reason := 'paid_at_in_future';
      v_detail := jsonb_build_object('paid_at', p_paid_at, 'server_now', now());
    end if;
  end if;

  -- b) El lugar de este cobro (orden, subcuenta, método, secuencia) ya tiene
  --    un pago: el mismo (respuesta perdida antes de los recibos) o de otro.
  if v_reason is null then
    if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
      v_method_id := p_payment_method_id::uuid;
    else
      select pm.id into v_method_id
        from public.payment_methods pm
       where pm.business_id = v_business and pm.code = p_payment_method_id
         and pm.is_active = true
       limit 1;
    end if;
    select * into v_existing
      from public.payments p
     where p.order_id = p_order_id
       and p.check_id is not distinct from p_check_id
       and p.payment_method_id is not distinct from v_method_id
       and p.split_sequence = coalesce(p_split_sequence, 0)
       and p.status = 'completed'
     limit 1;
    if v_existing.id is not null then
      if public.fn_offline_payment_matches(v_existing, v_request, p_cashier_session_id) then
        v_payment := v_existing;
      else
        v_reason := 'payment_slot_taken';
        v_detail := jsonb_build_object(
          'payment_id', v_existing.id, 'amount', v_existing.amount,
          'change_amount', v_existing.change_amount,
          'session_id', v_existing.session_id, 'created_at', v_existing.created_at);
      end if;
    end if;
  end if;

  -- c) La cuenta (o la subcuenta) ya está cobrada por otro lado.
  if v_reason is null and v_payment.id is null then
    if p_check_id is not null then
      select c.is_closed into v_closed
        from public.order_checks c
       where c.id = p_check_id and c.order_id = p_order_id;
      if not found then
        raise exception 'CHECK_OUT_OF_SCOPE' using errcode = '42501';
      end if;
    else
      v_closed := v_order.closed_at is not null
               or v_order.status_ext::text in ('paid', 'void');
    end if;
    if coalesce(v_closed, false) then
      -- 20261010_0020: lo tardío de una cuenta cerrada vuelve en una cuenta en
      -- revisión (orders.review_source_order_id). Sin esa migración, no hay.
      if exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'orders'
                    and column_name = 'review_source_order_id') then
        execute 'select o.id from public.orders o
                  where o.review_source_order_id = $1 and o.closed_at is null
                    and o.status_ext::text not in (''paid'', ''void'')
                  order by o.created_at desc limit 1'
           into v_review using p_order_id;
      end if;
      v_reason := case
        when v_order.status_ext::text = 'void' or v_order.status = 'canceled'
             or not exists (select 1 from public.payments p
                             where p.order_id = p_order_id and p.status = 'completed')
          then 'order_voided'
        else 'order_already_paid' end;
      v_detail := jsonb_build_object(
        'review_order_id', v_review,
        'order_status', v_order.status_ext::text, 'closed_at', v_order.closed_at,
        'payments', (select coalesce(jsonb_agg(jsonb_build_object(
                       'payment_id', p.id, 'amount', p.amount,
                       'change_amount', p.change_amount, 'session_id', p.session_id,
                       'created_at', p.created_at) order by p.created_at), '[]'::jsonb)
                       from public.payments p
                      where p.order_id = p_order_id and p.status = 'completed'
                        and p.check_id is not distinct from p_check_id));
    end if;
  end if;

  -- d) Aplicar con la v3 viva, en su caja y con su fecha.
  if v_reason is null and v_payment.id is null then
    select * into v_apply
      from public.fn_apply_offline_payment_locked(v_request, p_cashier_session_id, true);
    v_payment := v_apply.o_payment;
    v_reason := v_apply.o_reason;
    v_detail := v_apply.o_detail;
    if v_payment.id is not null
       and not public.fn_offline_payment_matches(v_payment, v_request, p_cashier_session_id) then
      raise exception 'PAYMENT_RESPONSE_MISMATCH' using errcode = 'MP431';
    end if;
  end if;

  v_money := public.fn_order_money_state_internal(p_order_id);

  insert into public.offline_payment_receipts as r (
    payment_key, business_id, order_id, check_id, request, cash_session_id,
    paid_at, amount, change_amount, payment_method, split_sequence, device_id,
    status, reason, detail, payment_id, applied_session_id, money)
  values (
    p_payment_key, v_business, p_order_id, p_check_id, v_request, p_cashier_session_id,
    (v_request ->> 'paid_at')::timestamptz, p_amount, coalesce(p_change_amount, 0),
    p_payment_method_id, coalesce(p_split_sequence, 0), p_device_id,
    case when v_payment.id is not null then 'applied' else 'needs_resolution' end,
    v_reason, v_detail, v_payment.id,
    case when v_payment.id is not null then p_cashier_session_id end, v_money)
  on conflict (payment_key) do update
    set status = excluded.status, reason = excluded.reason, detail = excluded.detail,
        payment_id = excluded.payment_id, applied_session_id = excluded.applied_session_id,
        money = excluded.money, request = excluded.request, updated_at = now()
  returning * into v_receipt;

  v_result := jsonb_build_object(
    'status', v_receipt.status, 'reason', v_receipt.reason, 'detail', v_receipt.detail,
    'payment_id', v_receipt.payment_id,
    'payment', case when v_payment.id is not null then to_jsonb(v_payment) end,
    'applied_session_id', v_receipt.applied_session_id,
    'money', v_money, 'replayed', false);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Resolver un cobro «por resolver» (decisión explícita)
-- ---------------------------------------------------------------------------
create or replace function public.fn_resolve_offline_payment(
  p_payment_key       uuid,
  p_resolution        text,
  p_target_session_id uuid default null,
  p_note              text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_receipt   public.offline_payment_receipts%rowtype;
  v_role      text;
  v_target    record;
  v_payment   public.payments;
  v_reason    text;
  v_detail    jsonb;
  v_session   uuid;
  v_paid_at   timestamptz;
  v_money     jsonb;
  v_apply     record;
begin
  select * into v_receipt
    from public.offline_payment_receipts
   where payment_key = p_payment_key;
  if not found then
    raise exception 'PAYMENT_RECEIPT_NOT_FOUND';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not (session_user in ('postgres', 'supabase_admin') and nullif(auth.role(), '') is null) then
    v_role := public.user_business_role(auth.uid(), v_receipt.business_id);
    if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
      raise exception 'RESOLVE_DENIED: solo el dueño, un administrador o un gerente'
        using errcode = '42501';
    end if;
  end if;

  -- El candado de la cuenta, y después el recibo.
  perform 1 from public.orders where id = v_receipt.order_id for update;
  select * into v_receipt
    from public.offline_payment_receipts
   where payment_key = p_payment_key
   for update;

  if v_receipt.status in ('resolved', 'acknowledged', 'applied') then
    -- Ya decidido (reintento de la misma decisión).
    return jsonb_build_object('status', v_receipt.status, 'resolution', v_receipt.resolution,
                              'payment_id', v_receipt.payment_id, 'replayed', true,
                              'money', public.fn_order_money_state_internal(v_receipt.order_id));
  end if;

  v_paid_at := (v_receipt.request ->> 'paid_at')::timestamptz;

  case p_resolution
    when 'acknowledge' then
      null;
    when 'post_to_open_session' then
      if v_receipt.reason not in ('cash_session_closed', 'cash_session_unknown', 'cash_session_missing') then
        raise exception 'RESOLUTION_NOT_ALLOWED: %', v_receipt.reason;
      end if;
      select cs.id, cs.status, cs.closed_at, cr.business_id into v_target
        from public.cash_register_sessions cs
        join public.cash_registers cr on cr.id = cs.cash_register_id
       where cs.id = p_target_session_id;
      if not found or v_target.business_id <> v_receipt.business_id
         or v_target.status <> 'open' or v_target.closed_at is not null then
        raise exception 'TARGET_SESSION_NOT_OPEN';
      end if;
      v_session := p_target_session_id;
    when 'apply_as_partial' then
      if v_receipt.reason <> 'order_changed' then
        raise exception 'RESOLUTION_NOT_ALLOWED: %', v_receipt.reason;
      end if;
      v_session := v_receipt.cash_session_id;
    when 'apply_anyway' then
      if v_receipt.reason <> 'paid_at_in_future' then
        raise exception 'RESOLUTION_NOT_ALLOWED: %', v_receipt.reason;
      end if;
      v_session := v_receipt.cash_session_id;
    when 'apply_to_review_order' then
      -- A la cuenta en revisión que nació de esa cuenta (20261010_0020), en la
      -- caja indicada o en la original.
      if v_receipt.reason not in ('order_already_paid', 'order_voided')
         or nullif(v_receipt.detail ->> 'review_order_id', '') is null then
        raise exception 'RESOLUTION_NOT_ALLOWED: %', v_receipt.reason;
      end if;
      perform 1 from public.orders
        where id = (v_receipt.detail ->> 'review_order_id')::uuid
          and closed_at is null for update;
      if not found then
        raise exception 'REVIEW_ORDER_NOT_OPEN';
      end if;
      v_receipt.request := v_receipt.request
        || jsonb_build_object('order_id', v_receipt.detail ->> 'review_order_id', 'check_id', null);
      v_session := coalesce(p_target_session_id, v_receipt.cash_session_id);
    else
      raise exception 'RESOLUTION_UNKNOWN: %', p_resolution;
  end case;

  if p_resolution <> 'acknowledge' then
    select * into v_apply
      from public.fn_apply_offline_payment_locked(
        v_receipt.request, v_session, p_resolution <> 'apply_as_partial');
    v_payment := v_apply.o_payment;
    v_reason := v_apply.o_reason;
    if v_payment.id is null then
      raise exception 'PAYMENT_NOT_APPLIED: %', coalesce(v_reason, 'desconocido');
    end if;
    if not public.fn_offline_payment_matches(v_payment, v_receipt.request, v_session) then
      raise exception 'PAYMENT_RESPONSE_MISMATCH' using errcode = 'MP431';
    end if;
    if p_resolution = 'post_to_open_session' then
      -- El efectivo de este cobro dice de qué caja cerrada y de cuándo viene.
      update public.cash_transactions ct
         set reason_code = 'late_offline_payment',
             description = format('Cobro sin red de la caja %s (%s), registrado tarde',
                                  coalesce(left(v_receipt.cash_session_id::text, 8), 'sin caja'),
                                  to_char(v_paid_at, 'YYYY-MM-DD HH24:MI'))
       where ct.session_id = v_session
         and ct.related_order_id = v_receipt.order_id
         and ct.type = 'sale'
         and ct.created_at = v_paid_at
         and ct.reason_code is null;
    end if;
  end if;

  v_money := public.fn_order_money_state_internal(v_receipt.order_id);
  update public.offline_payment_receipts
     set status = case when p_resolution = 'acknowledge' then 'acknowledged' else 'resolved' end,
         resolution = p_resolution,
         resolution_note = nullif(trim(coalesce(p_note, '')), ''),
         resolved_by = auth.uid(),
         resolved_at = now(),
         payment_id = v_payment.id,
         applied_session_id = case when v_payment.id is not null then v_session end,
         money = v_money,
         updated_at = now()
   where payment_key = p_payment_key
  returning * into v_receipt;

  return jsonb_build_object('status', v_receipt.status, 'resolution', p_resolution,
                            'payment_id', v_receipt.payment_id,
                            'applied_session_id', v_receipt.applied_session_id,
                            'money', v_money, 'replayed', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Lo que falta decidir o no cuadra
-- ---------------------------------------------------------------------------
create or replace function public.fn_offline_payment_issues(
  p_business_id uuid,
  p_since       timestamptz default now() - interval '30 days'
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (
    coalesce(auth.role(), '') = 'service_role'
    or (session_user in ('postgres', 'supabase_admin') and nullif(auth.role(), '') is null)
    or coalesce(public.is_member_of_business(p_business_id), false)
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  return query
  select jsonb_build_object(
           'payment_key', r.payment_key, 'order_id', r.order_id, 'check_id', r.check_id,
           'status', r.status, 'reason', r.reason, 'detail', r.detail,
           'amount', r.amount, 'change_amount', r.change_amount,
           'payment_method', r.payment_method, 'paid_at', r.paid_at,
           'cash_session_id', r.cash_session_id, 'applied_session_id', r.applied_session_id,
           'device_id', r.device_id, 'money', m.money)
    from public.offline_payment_receipts r
    cross join lateral (
      select public.fn_order_money_state_internal(r.order_id) as money
    ) m
   where r.business_id = p_business_id
     and r.created_at >= p_since
     and (r.status = 'needs_resolution'
          or jsonb_array_length(coalesce(m.money -> 'flags', '[]'::jsonb)) > 0)
   order by r.created_at;
end;
$$;

revoke all on function public.fn_order_money_state_internal(uuid) from public, anon, authenticated;
revoke all on function public.fn_apply_offline_payment_locked(jsonb, uuid, boolean) from public, anon, authenticated;
revoke all on function public.fn_offline_payment_matches(public.payments, jsonb, uuid) from public, anon, authenticated;
revoke all on function public.fn_order_money_state(uuid) from public, anon;
revoke all on function public.fn_replay_offline_payment(uuid, uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text, boolean, smallint, boolean, timestamptz, text, text, text) from public, anon;
revoke all on function public.fn_resolve_offline_payment(uuid, text, uuid, text) from public, anon;
revoke all on function public.fn_offline_payment_issues(uuid, timestamptz) from public, anon;
grant execute on function public.fn_order_money_state(uuid) to authenticated, service_role;
grant execute on function public.fn_replay_offline_payment(uuid, uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text, boolean, smallint, boolean, timestamptz, text, text, text) to authenticated, service_role;
grant execute on function public.fn_resolve_offline_payment(uuid, text, uuid, text) to authenticated, service_role;
grant execute on function public.fn_offline_payment_issues(uuid, timestamptz) to authenticated, service_role;

commit;
