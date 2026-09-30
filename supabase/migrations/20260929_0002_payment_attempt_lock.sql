-- =============================================================================
-- 20260929_0002_payment_attempt_lock.sql
-- Un solo cobro a la vez por cuenta, entre TODOS los equipos.
-- Plan de cierre offline (docs/PLAN_CIERRE_OFFLINE_INTRANET_WINDOWS.md), P0
-- cobros: "bloquee la cuenta ... nunca cobrar dos veces".
--
-- Problema (verificado en fn_process_payment_v3, 20260612_0001): un abono
-- parcial (p_close_order/p_close_check = false) solo inserta el pago, sin mirar
-- el saldo. Y la pantalla de la mesa no descuenta lo ya cobrado. Así:
--   * dos PC cobrando la MISMA cuenta a la vez (una en abonos, otra completa)
--     cobraban de más;
--   * un cobro dividido que quedó a medias (40 de 100) y se abre en OTRA PC se
--     cobraba completo (100) → 140 por una cuenta de 100.
--
-- Solución:
--   1. order_payment_attempts: candado por ORDEN con vencimiento (la orden
--      completa y sus subcuentas comparten candado, porque el cobro de la orden
--      completa marca pagado todo). Si la app muere, vence solo.
--   2. fn_payment_attempt_acquire: toma el candado (mismo FOR UPDATE de la orden
--      que usa el cobro) y devuelve lo cobrado por OTROS intentos en ese alcance
--      y el siguiente split_sequence libre, para cobrar solo el restante sin
--      chocar con el índice único de pagos.
--   3. fn_process_payment_v3_attempt: llama a la fn_process_payment_v3 VIVA tal
--      cual (misma lista de parámetros nombrados que ya manda la app; no se
--      reemplaza, la BD viva diverge del repo), renueva el candado en cada
--      abono y lo suelta cuando el abono cierra la cuenta.
--   4. Trigger en payments: si otro intento tiene el candado vigente, el pago
--      no entra — también para builds viejos, el modal simple o el replay de la
--      cola offline, que no conocen el candado. Sin candado vigente no cambia
--      nada (compatible). Estampa payments.client_attempt_id.
--
-- Rollback: 20260929_0002_payment_attempt_lock_ROLLBACK.sql
-- =============================================================================

begin;

alter table public.payments
  add column if not exists client_attempt_id uuid;

comment on column public.payments.client_attempt_id is
  'Intento de cobro (modal) que registró este pago. Lo estampa el trigger '
  'desde fn_process_payment_v3_attempt. NULL = cobro sin candado (build viejo, '
  'modal simple, replay offline).';

create table if not exists public.order_payment_attempts (
  order_id uuid primary key,
  attempt_id uuid not null,
  check_id uuid,
  device_id text,
  holder_label text,
  started_at timestamptz not null default now(),
  expires_at timestamptz not null
);

comment on table public.order_payment_attempts is
  'Candado de cobro por orden (un intento a la vez entre equipos). Solo lo tocan '
  'fn_payment_attempt_acquire / _release / fn_process_payment_v3_attempt.';

alter table public.order_payment_attempts enable row level security;
revoke all on table public.order_payment_attempts from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Tomar el candado.
-- -----------------------------------------------------------------------------
create or replace function public.fn_payment_attempt_acquire(
  p_order_id uuid,
  p_attempt_id uuid,
  p_check_id uuid default null,
  p_device_id text default null,
  p_holder_label text default null,
  p_ttl_seconds integer default 120
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
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
$$;

-- -----------------------------------------------------------------------------
-- Soltar el candado (cobro abortado antes de escribir). Idempotente.
-- -----------------------------------------------------------------------------
create or replace function public.fn_payment_attempt_release(
  p_order_id uuid,
  p_attempt_id uuid
) returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
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
$$;

-- -----------------------------------------------------------------------------
-- Cobro con candado. Misma lista de parámetros nombrados que la app manda hoy a
-- fn_process_payment_v3, más p_attempt_id y p_ttl_seconds.
-- -----------------------------------------------------------------------------
create or replace function public.fn_process_payment_v3_attempt(
  p_attempt_id uuid,
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
  p_ttl_seconds integer default 120,
  p_offline_ncf text default null
) returns public.payments
language plpgsql
security definer
set search_path to 'public'
as $$
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
$$;

-- -----------------------------------------------------------------------------
-- Guardia en payments. SECURITY DEFINER: la tabla del candado no es legible
-- para authenticated y hay inserciones que no pasan por funciones definer.
-- Nombre con 000 para correr antes que los demás BEFORE INSERT (alfabético):
-- si revienta, no llega a gastar número fiscal (igual se revertiría todo).
-- -----------------------------------------------------------------------------
create or replace function public.fn_payments_attempt_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_attempt uuid := nullif(current_setting('mangopos.payment_attempt_id', true), '')::uuid;
  v_lease public.order_payment_attempts%rowtype;
begin
  if v_attempt is not null and new.client_attempt_id is null then
    new.client_attempt_id := v_attempt;
  end if;

  if new.order_id is null then
    return new;
  end if;

  select * into v_lease
  from public.order_payment_attempts
  where order_id = new.order_id;

  if found
     and v_lease.expires_at > now()
     and v_lease.attempt_id is distinct from v_attempt then
    raise exception 'PAYMENT_LOCKED_BY_OTHER_DEVICE'
      using errcode = 'MP420',
            detail = coalesce(v_lease.holder_label, ''),
            hint = coalesce(v_lease.device_id, '');
  end if;

  return new;
end;
$$;

drop trigger if exists trg_000_payments_attempt_guard on public.payments;
create trigger trg_000_payments_attempt_guard
  before insert on public.payments
  for each row
  execute function public.fn_payments_attempt_guard();

-- Supabase concede EXECUTE a anon por privilegios por defecto: revocar
-- explícito además de public.
revoke all on function public.fn_payment_attempt_acquire(uuid, uuid, uuid, text, text, integer) from public, anon;
revoke all on function public.fn_payment_attempt_release(uuid, uuid) from public, anon;
revoke all on function public.fn_process_payment_v3_attempt(
  uuid, uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text,
  boolean, smallint, boolean, timestamptz, integer, text
) from public, anon;
revoke all on function public.fn_payments_attempt_guard() from public, anon, authenticated;

grant execute on function public.fn_payment_attempt_acquire(uuid, uuid, uuid, text, text, integer) to authenticated, service_role;
grant execute on function public.fn_payment_attempt_release(uuid, uuid) to authenticated, service_role;
grant execute on function public.fn_process_payment_v3_attempt(
  uuid, uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text,
  boolean, smallint, boolean, timestamptz, integer, text
) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
