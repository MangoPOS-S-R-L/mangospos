-- =============================================================================
-- 20260917_0007 — Abono (saldo prepagado) por mesa
-- =============================================================================
--
-- QUÉ ES:
--   La mesa tiene una cuenta de saldo prepagado. El cliente abona (ej. 10,000),
--   el dinero entra a la caja EN ESE MOMENTO, y cada factura que se cobre en
--   esa mesa descuenta del saldo en vez de cobrar dinero nuevo. La factura
--   imprime cuánto quedó. Si el consumo pasa del saldo, la diferencia se cobra
--   con otro método (pago mixto: 9,000 de saldo + 500 en efectivo).
--
-- DECISIONES (confirmadas con el negocio):
--   1. El saldo vive en la MESA FÍSICA (dining_tables), no en la visita. No se
--      muere al cerrar la mesa ni al cerrar la caja: dura hasta agotarse.
--   2. El dinero entra al abonar. El abono NO es una venta: no lleva NCF y no
--      toca `payments`. Entra como `cash_transactions` type='deposit' (igual
--      que el abono de crédito, 20260714_0002), o sea que suma al efectivo
--      esperado del cierre.
--   3. El consumo contra el saldo SÍ es una venta: `payments` con método
--      code='table_deposit' → NCF normal, reportes de ventas normales. Como no
--      es 'cash', `fn_process_payment_v3` no le escribe cash_transactions y el
--      efectivo esperado no se infla. El dinero ya había entrado al abonar.
--
-- POR QUÉ UN TRIGGER Y NO UN RPC NUEVO DE COBRO:
--   `fn_process_payment_v3` es la función más sensible del sistema y la versión
--   VIVA diverge de la del repo (tiene p_close_order, p_split_sequence,
--   p_offline_ncf... que schema.sql no muestra) — ver
--   [[project_db_diverges_from_repo_migrations]]. Tocarla para esto sería
--   arriesgar el cobro entero. En vez de eso el débito del saldo cuelga de un
--   trigger sobre `payments`, así que funciona igual desde el modal simple, el
--   cobro mixto, el split por sub-cuenta y el replay de la cola offline, sin
--   editar una sola línea del RPC de cobro.
--
-- EFECTO EN EL CIERRE DE CAJA (ejemplo del negocio):
--   abono 10,000 efectivo  → cash_transactions 'deposit' +10,000 → efectivo esperado +10,000
--   factura 1,000 c/ saldo → payments table_deposit           → efectivo esperado +0
--   factura 9,500: 9,000 saldo + 500 efectivo                 → efectivo esperado +500
--   Total esperado en gaveta: 10,500 ✔ (y ventas reportadas: 10,500 ✔)
--
-- PENDIENTE CONOCIDO (no lo resuelve esta migración):
--   El abono cobrado con TARJETA/TRANSFERENCIA no entra a expected_card /
--   expected_transfer de `fn_get_cash_session_summary`, porque esa función los
--   calcula solo desde `payments` y el abono no es un payment. Queda registrado
--   en el ledger y visible en el reporte de abonos. Arreglarlo obliga a
--   recrear la función del cierre — va aparte (F3) y exige verificar antes la
--   definición VIVA con pg_get_functiondef. Mismo hueco que ya tiene el abono
--   de crédito hoy.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Cuenta de saldo por mesa física
-- ---------------------------------------------------------------------------

create table if not exists public.table_deposit_accounts (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references public.businesses(id) on delete cascade,
  table_id         uuid not null references public.dining_tables(id) on delete cascade,
  balance          numeric(12,2) not null default 0,
  total_deposited  numeric(12,2) not null default 0,
  total_consumed   numeric(12,2) not null default 0,
  total_refunded   numeric(12,2) not null default 0,
  -- A nombre de quién está el abono. Es la única defensa práctica contra el
  -- riesgo del modelo por mesa física: que el próximo cliente que se siente
  -- se coma el saldo del anterior. La app lo muestra antes de aplicarlo.
  holder_name      text,
  note             text,
  last_movement_at timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint table_deposit_accounts_table_uniq unique (table_id),
  constraint table_deposit_accounts_balance_nonneg check (balance >= 0)
);

comment on table public.table_deposit_accounts is
  'Saldo prepagado por mesa física. El cliente abona, el dinero entra a la '
  'caja al abonar, y el consumo de esa mesa se descuenta de aquí. El saldo '
  'sobrevive al cierre de la visita y al cierre de caja: dura hasta agotarse.';

comment on column public.table_deposit_accounts.holder_name is
  'A nombre de quién está el abono. El saldo vive en la mesa física, así que '
  'esto es lo que le permite al cajero ver de quién es antes de aplicarlo.';

create index if not exists idx_table_deposit_accounts_business
  on public.table_deposit_accounts (business_id)
  where balance > 0;

-- ---------------------------------------------------------------------------
-- 2. Ledger de movimientos
-- ---------------------------------------------------------------------------

create table if not exists public.table_deposit_movements (
  id                uuid primary key default gen_random_uuid(),
  account_id        uuid not null references public.table_deposit_accounts(id) on delete cascade,
  business_id       uuid not null,
  table_id          uuid not null,
  -- deposit    : el cliente abonó (entra plata)
  -- consumption: se facturó contra el saldo (sale saldo)
  -- reversal   : se anuló un cobro hecho contra el saldo (vuelve el saldo)
  -- refund     : se le devolvió efectivo al cliente (sale plata de la caja)
  -- transfer_in / transfer_out: el saldo se movió a otra mesa (abono cargado
  --              a la mesa equivocada — pasa, y sin esto hay que tocar la BD)
  -- adjustment : corrección manual con permiso
  type              text not null,
  -- Firmado: positivo entra al saldo, negativo sale.
  amount            numeric(12,2) not null,
  balance_after     numeric(12,2) not null,
  order_id          uuid,
  check_id          uuid,
  payment_id        uuid references public.payments(id) on delete set null,
  table_session_id  uuid,
  payment_method_id uuid references public.payment_methods(id),
  cash_session_id   uuid,
  -- Contraparte de un transfer_in/transfer_out.
  related_table_id  uuid,
  reference         text,
  note              text,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  constraint table_deposit_movements_type_check check (
    type in ('deposit', 'consumption', 'reversal', 'refund',
             'transfer_in', 'transfer_out', 'adjustment')
  ),
  constraint table_deposit_movements_amount_nonzero check (amount <> 0)
);

comment on table public.table_deposit_movements is
  'Ledger del saldo de mesa. Cada fila deja balance_after, así que la factura '
  'puede imprimir "saldo restante" leyendo el movimiento de su propio pago.';

create index if not exists idx_table_deposit_movements_account
  on public.table_deposit_movements (account_id, created_at desc);

create index if not exists idx_table_deposit_movements_payment
  on public.table_deposit_movements (payment_id)
  where payment_id is not null;

create index if not exists idx_table_deposit_movements_order
  on public.table_deposit_movements (order_id)
  where order_id is not null;

create index if not exists idx_table_deposit_movements_business_date
  on public.table_deposit_movements (business_id, created_at desc);

-- Un pago solo puede descontar del saldo UNA vez, y solo puede revertirse una
-- vez. Es el candado real contra el doble descuento por reintento del RPC.
create unique index if not exists uq_table_deposit_movements_payment_type
  on public.table_deposit_movements (payment_id, type)
  where payment_id is not null;

-- ---------------------------------------------------------------------------
-- 3. RLS — lectura por negocio; toda escritura pasa por los RPC de abajo
-- ---------------------------------------------------------------------------

alter table public.table_deposit_accounts  enable row level security;
alter table public.table_deposit_movements enable row level security;

drop policy if exists tda_select on public.table_deposit_accounts;
create policy tda_select on public.table_deposit_accounts
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists tdm_select on public.table_deposit_movements;
create policy tdm_select on public.table_deposit_movements
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

grant select on public.table_deposit_accounts  to authenticated;
grant select on public.table_deposit_movements to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Método de pago 'table_deposit'
-- ---------------------------------------------------------------------------
-- Es el método con el que se cobra contra el saldo. No es dinero nuevo: el
-- dinero entró al abonar. Va con is_active=true para que aparezca en el cobro;
-- la app lo esconde cuando la mesa no tiene saldo.

create unique index if not exists uq_payment_methods_table_deposit
  on public.payment_methods (business_id)
  where code = 'table_deposit';

insert into public.payment_methods (business_id, name, code, is_active,
                                    requires_reference, icon, position)
select b.id, 'Saldo de mesa', 'table_deposit', true, false, 'wallet', 90
from public.businesses b
on conflict do nothing;

-- Negocios creados después de esta migración: el RPC de abono lo crea al
-- primer uso, así que no hace falta un trigger sobre businesses.
create or replace function public.fn_ensure_table_deposit_method(
  p_business_id uuid
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_id uuid;
begin
  select pm.id into v_id
  from public.payment_methods pm
  where pm.business_id = p_business_id
    and pm.code = 'table_deposit'
  limit 1;

  if v_id is null then
    insert into public.payment_methods (business_id, name, code, is_active,
                                        requires_reference, icon, position)
    values (p_business_id, 'Saldo de mesa', 'table_deposit', true, false,
            'wallet', 90)
    returning id into v_id;
  elsif exists (
    select 1 from public.payment_methods pm
    where pm.id = v_id and pm.is_active is distinct from true
  ) then
    update public.payment_methods set is_active = true where id = v_id;
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Helper: resolver la cuenta de una mesa (creándola si no existe)
-- ---------------------------------------------------------------------------

create or replace function public.fn_table_deposit_account(
  p_table_id uuid,
  p_create   boolean default false
) returns public.table_deposit_accounts
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_account     public.table_deposit_accounts;
  v_business_id uuid;
begin
  select a.* into v_account
  from public.table_deposit_accounts a
  where a.table_id = p_table_id;

  if found then
    return v_account;
  end if;

  if not p_create then
    return v_account; -- fila nula: la mesa no tiene cuenta todavía
  end if;

  select z.business_id into v_business_id
  from public.dining_tables dt
  join public.zones z on z.id = dt.zone_id
  where dt.id = p_table_id;

  if v_business_id is null then
    raise exception 'TABLE_NOT_FOUND';
  end if;

  insert into public.table_deposit_accounts (business_id, table_id)
  values (v_business_id, p_table_id)
  on conflict (table_id) do update set updated_at = now()
  returning * into v_account;

  return v_account;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Registrar un abono (entra el dinero)
-- ---------------------------------------------------------------------------

create or replace function public.fn_table_deposit_add(
  p_table_id           uuid,
  p_amount             numeric,
  p_payment_method_id  text    default 'cash',
  p_cashier_session_id uuid    default null,
  p_reference          text    default null,
  p_holder_name        text    default null,
  p_note               text    default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_account       public.table_deposit_accounts;
  v_business_id   uuid;
  v_method_id     uuid;
  v_method_code   text;
  v_movement_id   uuid;
  v_table_label   text;
begin
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'DEPOSIT_INVALID_AMOUNT';
  end if;

  select z.business_id, coalesce(dt.label, dt.code)
    into v_business_id, v_table_label
  from public.dining_tables dt
  join public.zones z on z.id = dt.zone_id
  where dt.id = p_table_id;

  if v_business_id is null then
    raise exception 'TABLE_NOT_FOUND';
  end if;

  if not public.user_has_business_access(auth.uid(), v_business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  -- La caja tiene que estar abierta: el dinero entra AHORA, y sin sesión no
  -- hay dónde registrarlo (mismo criterio que fn_process_payment_v3).
  if p_cashier_session_id is null then
    raise exception 'CASH_SESSION_REQUIRED';
  end if;

  perform 1
  from public.cash_register_sessions s
  where s.id = p_cashier_session_id
    and s.status = 'open'
    and s.closed_at is null;

  if not found then
    raise exception 'CASH_SESSION_NOT_OPEN';
  end if;

  -- Método con el que el cliente pagó el abono (efectivo, tarjeta...).
  if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
    select pm.id, pm.code into v_method_id, v_method_code
    from public.payment_methods pm
    where pm.id = p_payment_method_id::uuid
      and pm.business_id = v_business_id
    limit 1;
  else
    select pm.id, pm.code into v_method_id, v_method_code
    from public.payment_methods pm
    where pm.business_id = v_business_id
      and pm.code = coalesce(p_payment_method_id, 'cash')
      and pm.is_active = true
    limit 1;
  end if;

  if v_method_id is null then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  -- Cobrar el abono CON saldo de mesa sería mover plata en círculo.
  if v_method_code = 'table_deposit' then
    raise exception 'DEPOSIT_METHOD_NOT_ALLOWED';
  end if;

  -- El método con el que DESPUÉS se cobra contra este saldo tiene que existir
  -- antes de que haya saldo. Los negocios creados después de esta migración no
  -- lo tienen (el seed de abajo solo cubrió los de ese momento), y sin él el
  -- cajero podría abonar pero nunca gastar lo abonado.
  perform public.fn_ensure_table_deposit_method(v_business_id);

  v_account := public.fn_table_deposit_account(p_table_id, true);

  update public.table_deposit_accounts a
     set balance          = a.balance + p_amount,
         total_deposited  = a.total_deposited + p_amount,
         holder_name      = coalesce(nullif(trim(coalesce(p_holder_name, '')), ''),
                                     a.holder_name),
         note             = coalesce(nullif(trim(coalesce(p_note, '')), ''), a.note),
         last_movement_at = now(),
         updated_at       = now()
   where a.id = v_account.id
  returning * into v_account;

  insert into public.table_deposit_movements (
    account_id, business_id, table_id, type, amount, balance_after,
    payment_method_id, cash_session_id, reference, note, created_by
  ) values (
    v_account.id, v_business_id, p_table_id, 'deposit', p_amount,
    v_account.balance, v_method_id, p_cashier_session_id, p_reference,
    p_note, auth.uid()
  )
  returning id into v_movement_id;

  -- Solo el efectivo entra a la gaveta. Tarjeta/transferencia quedan en el
  -- ledger (ver "PENDIENTE CONOCIDO" en la cabecera).
  if v_method_code = 'cash' then
    insert into public.cash_transactions (session_id, amount, type, description)
    values (
      p_cashier_session_id,
      p_amount,
      'deposit',
      'Abono mesa ' || coalesce(v_table_label, left(p_table_id::text, 8))
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'account_id', v_account.id,
    'movement_id', v_movement_id,
    'table_id', p_table_id,
    'table_label', v_table_label,
    'amount', p_amount,
    'balance', v_account.balance,
    'total_deposited', v_account.total_deposited,
    'total_consumed', v_account.total_consumed,
    'holder_name', v_account.holder_name,
    'payment_method_code', v_method_code,
    'entered_cash_drawer', (v_method_code = 'cash')
  );
end;
$$;

comment on function public.fn_table_deposit_add(uuid, numeric, text, uuid, text, text, text) is
  'Registra un abono prepagado a una mesa. El dinero entra a la caja en este '
  'momento (cash_transactions type=deposit si es efectivo). NO emite NCF: el '
  'abono no es una venta, la venta es el consumo posterior.';

-- ---------------------------------------------------------------------------
-- 7. El consumo: trigger sobre `payments`
-- ---------------------------------------------------------------------------
-- Cuelga del INSERT de payments en vez de tocar fn_process_payment_v3, así
-- cubre solo el modal, el cobro mixto, el split por sub-cuenta y el replay de
-- la cola offline sin editar el RPC de cobro.

create or replace function public.fn_table_deposit_on_payment()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_code       text;
  v_table_id   uuid;
  v_session_id uuid;
  v_account    public.table_deposit_accounts;
begin
  if coalesce(new.status, '') <> 'completed' then
    return new;
  end if;

  select pm.code into v_code
  from public.payment_methods pm
  where pm.id = new.payment_method_id;

  if coalesce(v_code, '') <> 'table_deposit' then
    return new;
  end if;

  if coalesce(new.amount, 0) <= 0 then
    raise exception 'TABLE_DEPOSIT_INVALID_AMOUNT';
  end if;

  -- Contra el saldo no se da vuelto: lo que no alcanza se cobra con otro
  -- método, no se devuelve efectivo del saldo prepagado.
  if coalesce(new.change_amount, 0) > 0 then
    raise exception 'TABLE_DEPOSIT_NO_CHANGE';
  end if;

  select o.session_id, ts.table_id
    into v_session_id, v_table_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  where o.id = new.order_id;

  if v_table_id is null then
    -- Venta rápida / manual: no hay mesa de la cual descontar.
    raise exception 'TABLE_DEPOSIT_NO_TABLE';
  end if;

  -- Débito atómico: el `balance >= amount` en el WHERE es el candado contra
  -- dos cajeros cobrando la misma mesa al mismo tiempo.
  update public.table_deposit_accounts a
     set balance          = a.balance - new.amount,
         total_consumed   = a.total_consumed + new.amount,
         last_movement_at = now(),
         updated_at       = now()
   where a.table_id = v_table_id
     and a.balance >= new.amount
  returning * into v_account;

  if not found then
    raise exception 'TABLE_DEPOSIT_INSUFFICIENT'
      using detail = 'La mesa no tiene saldo suficiente para cubrir '
                     || new.amount::text;
  end if;

  insert into public.table_deposit_movements (
    account_id, business_id, table_id, type, amount, balance_after,
    order_id, check_id, payment_id, table_session_id, payment_method_id,
    cash_session_id, created_by
  ) values (
    v_account.id, v_account.business_id, v_table_id, 'consumption',
    -new.amount, v_account.balance, new.order_id, new.check_id, new.id,
    v_session_id, new.payment_method_id, new.session_id, new.processed_by
  );

  return new;
end;
$$;

drop trigger if exists trg_table_deposit_on_payment on public.payments;
create trigger trg_table_deposit_on_payment
  after insert on public.payments
  for each row
  execute function public.fn_table_deposit_on_payment();

-- Anulación: el saldo vuelve a la mesa.
create or replace function public.fn_table_deposit_on_payment_void()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_code    text;
  v_account public.table_deposit_accounts;
  v_consumed public.table_deposit_movements;
begin
  if coalesce(old.status, '') <> 'completed' then
    return new;
  end if;

  if coalesce(new.status, '') not in ('cancelled', 'void', 'refunded') then
    return new;
  end if;

  select pm.code into v_code
  from public.payment_methods pm
  where pm.id = new.payment_method_id;

  if coalesce(v_code, '') <> 'table_deposit' then
    return new;
  end if;

  -- Solo se devuelve lo que efectivamente se descontó.
  select m.* into v_consumed
  from public.table_deposit_movements m
  where m.payment_id = new.id
    and m.type = 'consumption'
  limit 1;

  if not found then
    return new;
  end if;

  -- Candado contra la doble devolución, ANTES de tocar el saldo.
  --
  -- El unique index (payment_id, type) protege el ledger pero NO el balance:
  -- si el update va primero, un segundo 'cancelled' sobre el mismo pago suma
  -- el saldo otra vez y el `on conflict do nothing` se come la evidencia. Pasa
  -- de verdad — basta con que alguien reactive un pago anulado y lo vuelva a
  -- anular (cancelled → completed → cancelled): el saldo se duplica y el
  -- ledger no lo muestra. Verificado en local: 9,000 se convertían en 18,000.
  if exists (
    select 1 from public.table_deposit_movements m
    where m.payment_id = new.id
      and m.type = 'reversal'
  ) then
    return new;
  end if;

  update public.table_deposit_accounts a
     set balance          = a.balance + abs(v_consumed.amount),
         total_consumed   = greatest(a.total_consumed - abs(v_consumed.amount), 0),
         last_movement_at = now(),
         updated_at       = now()
   where a.id = v_consumed.account_id
  returning * into v_account;

  if not found then
    -- La cuenta ya no existe (mesa borrada). No hay saldo al cual devolver;
    -- la anulación del pago sigue siendo válida.
    return new;
  end if;

  -- El unique index (payment_id, type) hace que una segunda anulación del
  -- mismo pago no devuelva el saldo dos veces.
  insert into public.table_deposit_movements (
    account_id, business_id, table_id, type, amount, balance_after,
    order_id, check_id, payment_id, table_session_id, created_by,
    note
  ) values (
    v_consumed.account_id, v_consumed.business_id, v_consumed.table_id,
    'reversal', abs(v_consumed.amount), v_account.balance,
    v_consumed.order_id, v_consumed.check_id, new.id,
    v_consumed.table_session_id, auth.uid(),
    'Devuelto por anulación del cobro'
  )
  on conflict (payment_id, type) where payment_id is not null do nothing;

  return new;
end;
$$;

drop trigger if exists trg_table_deposit_on_payment_void on public.payments;
create trigger trg_table_deposit_on_payment_void
  after update of status on public.payments
  for each row
  when (old.status is distinct from new.status)
  execute function public.fn_table_deposit_on_payment_void();

-- Candado: no se puede cambiar el método de pago entrando o saliendo del
-- saldo de mesa.
--
-- "Editar método de pago" del historial de ventas hace un UPDATE directo de
-- payment_method_id. Como el débito del saldo cuelga del INSERT, ese cambio
-- dejaría el saldo desfasado: pasar A saldo regala el consumo (nunca se
-- descuenta) y salir DE saldo no lo devuelve. El camino correcto es anular y
-- recobrar, que sí pasa por los dos triggers. La app ya lo bloquea con un
-- mensaje claro (igual que hace con el crédito); esto es el respaldo del
-- servidor, porque el error crea o destruye dinero.
create or replace function public.fn_table_deposit_block_method_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_old_code text;
  v_new_code text;
begin
  select pm.code into v_old_code
  from public.payment_methods pm where pm.id = old.payment_method_id;

  select pm.code into v_new_code
  from public.payment_methods pm where pm.id = new.payment_method_id;

  if coalesce(v_old_code, '') = 'table_deposit'
     or coalesce(v_new_code, '') = 'table_deposit' then
    raise exception 'TABLE_DEPOSIT_METHOD_CHANGE_BLOCKED'
      using detail = 'Anula el cobro (el saldo vuelve a la mesa) y cobra de '
                     'nuevo con el método correcto.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_table_deposit_block_method_change on public.payments;
create trigger trg_table_deposit_block_method_change
  before update of payment_method_id on public.payments
  for each row
  when (old.payment_method_id is distinct from new.payment_method_id)
  execute function public.fn_table_deposit_block_method_change();

-- ---------------------------------------------------------------------------
-- 8. Devolver saldo en efectivo
-- ---------------------------------------------------------------------------
-- El negocio decidió que el saldo dura hasta agotarse, así que esto NO es
-- parte del flujo normal: es la salida para el error humano (abono cargado de
-- más, cliente que no vuelve y reclama). Sale plata de la caja, así que pide
-- sesión abierta y queda firmado.

create or replace function public.fn_table_deposit_refund(
  p_table_id           uuid,
  p_amount             numeric,
  p_cashier_session_id uuid,
  p_note               text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_account     public.table_deposit_accounts;
  v_table_label text;
begin
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'DEPOSIT_INVALID_AMOUNT';
  end if;

  select a.* into v_account
  from public.table_deposit_accounts a
  where a.table_id = p_table_id;

  if not found then
    raise exception 'TABLE_DEPOSIT_ACCOUNT_NOT_FOUND';
  end if;

  if not public.user_has_business_access(auth.uid(), v_account.business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  if p_cashier_session_id is null then
    raise exception 'CASH_SESSION_REQUIRED';
  end if;

  perform 1
  from public.cash_register_sessions s
  where s.id = p_cashier_session_id
    and s.status = 'open'
    and s.closed_at is null;

  if not found then
    raise exception 'CASH_SESSION_NOT_OPEN';
  end if;

  update public.table_deposit_accounts a
     set balance          = a.balance - p_amount,
         total_refunded   = a.total_refunded + p_amount,
         last_movement_at = now(),
         updated_at       = now()
   where a.id = v_account.id
     and a.balance >= p_amount
  returning * into v_account;

  if not found then
    raise exception 'TABLE_DEPOSIT_INSUFFICIENT';
  end if;

  select coalesce(dt.label, dt.code) into v_table_label
  from public.dining_tables dt where dt.id = p_table_id;

  insert into public.table_deposit_movements (
    account_id, business_id, table_id, type, amount, balance_after,
    cash_session_id, note, created_by
  ) values (
    v_account.id, v_account.business_id, p_table_id, 'refund', -p_amount,
    v_account.balance, p_cashier_session_id, p_note, auth.uid()
  );

  insert into public.cash_transactions (session_id, amount, type, description)
  values (
    p_cashier_session_id,
    p_amount,
    'withdrawal',
    'Devolución de abono mesa ' || coalesce(v_table_label, left(p_table_id::text, 8))
  );

  return jsonb_build_object(
    'success', true,
    'table_id', p_table_id,
    'amount', p_amount,
    'balance', v_account.balance
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Mover saldo a otra mesa
-- ---------------------------------------------------------------------------
-- El abono cargado a la mesa equivocada es el error más probable de este
-- módulo. Sin esto hay que entrar a la BD a mano.

create or replace function public.fn_table_deposit_transfer(
  p_from_table_id uuid,
  p_to_table_id   uuid,
  p_amount        numeric,
  p_note          text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_from public.table_deposit_accounts;
  v_to   public.table_deposit_accounts;
begin
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'DEPOSIT_INVALID_AMOUNT';
  end if;

  if p_from_table_id = p_to_table_id then
    raise exception 'DEPOSIT_SAME_TABLE';
  end if;

  select a.* into v_from
  from public.table_deposit_accounts a
  where a.table_id = p_from_table_id;

  if not found then
    raise exception 'TABLE_DEPOSIT_ACCOUNT_NOT_FOUND';
  end if;

  if not public.user_has_business_access(auth.uid(), v_from.business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  v_to := public.fn_table_deposit_account(p_to_table_id, true);

  if v_to.business_id <> v_from.business_id then
    raise exception 'DEPOSIT_CROSS_BUSINESS';
  end if;

  update public.table_deposit_accounts a
     set balance          = a.balance - p_amount,
         last_movement_at = now(),
         updated_at       = now()
   where a.id = v_from.id
     and a.balance >= p_amount
  returning * into v_from;

  if not found then
    raise exception 'TABLE_DEPOSIT_INSUFFICIENT';
  end if;

  update public.table_deposit_accounts a
     set balance          = a.balance + p_amount,
         holder_name      = coalesce(a.holder_name, v_from.holder_name),
         last_movement_at = now(),
         updated_at       = now()
   where a.id = v_to.id
  returning * into v_to;

  insert into public.table_deposit_movements (
    account_id, business_id, table_id, type, amount, balance_after,
    related_table_id, note, created_by
  ) values (
    v_from.id, v_from.business_id, p_from_table_id, 'transfer_out', -p_amount,
    v_from.balance, p_to_table_id, p_note, auth.uid()
  ), (
    v_to.id, v_to.business_id, p_to_table_id, 'transfer_in', p_amount,
    v_to.balance, p_from_table_id, p_note, auth.uid()
  );

  return jsonb_build_object(
    'success', true,
    'from_balance', v_from.balance,
    'to_balance', v_to.balance,
    'amount', p_amount
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Lectura: saldos de un negocio / de una mesa
-- ---------------------------------------------------------------------------

create or replace function public.fn_table_deposit_balances(
  p_business_id uuid
) returns table (
  table_id       uuid,
  table_code     text,
  table_label    text,
  zone_id        uuid,
  balance        numeric,
  holder_name    text,
  last_movement_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    a.table_id,
    dt.code,
    coalesce(dt.label, dt.code),
    dt.zone_id,
    a.balance,
    a.holder_name,
    a.last_movement_at
  from public.table_deposit_accounts a
  join public.dining_tables dt on dt.id = a.table_id
  where a.business_id = p_business_id
    and a.balance > 0
    and public.user_has_business_access(auth.uid(), a.business_id)
  order by a.last_movement_at desc nulls last;
$$;

-- Saldo de la mesa a la que pertenece una orden. El modal de cobro tiene la
-- orden pero no la mesa (`Order` solo carga session_id), así que sin esto el
-- cobro necesitaría dos viajes extra para saber si ofrecer el saldo.
create or replace function public.fn_table_deposit_balance_for_order(
  p_order_id uuid
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'table_id', ts.table_id,
    'table_label', coalesce(dt.label, dt.code),
    'balance', coalesce(a.balance, 0),
    'holder_name', a.holder_name,
    'account_id', a.id
  )
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  join public.dining_tables dt on dt.id = ts.table_id
  join public.zones z on z.id = dt.zone_id
  left join public.table_deposit_accounts a on a.table_id = ts.table_id
  where o.id = p_order_id
    and public.user_has_business_access(auth.uid(), z.business_id)
  limit 1;
$$;

-- Saldo restante que dejó un cobro: es lo que la factura imprime como
-- "monto restante". Se lee por payment_id para que la reimpresión saque el
-- mismo número que el ticket original y no el saldo de hoy.
create or replace function public.fn_table_deposit_for_payment(
  p_payment_id uuid
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'applied', abs(m.amount),
    'balance_after', m.balance_after,
    'table_id', m.table_id,
    'created_at', m.created_at
  )
  from public.table_deposit_movements m
  where m.payment_id = p_payment_id
    and m.type = 'consumption'
    and public.user_has_business_access(auth.uid(), m.business_id)
  limit 1;
$$;

-- Lo mismo pero por orden: el ticket se arma antes de conocer cada payment_id
-- cuando el cobro fue mixto. Devuelve el total aplicado y el saldo que quedó.
create or replace function public.fn_table_deposit_for_order(
  p_order_id uuid
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'applied', coalesce(sum(abs(m.amount)), 0),
    'balance_after', (
      select m2.balance_after
      from public.table_deposit_movements m2
      where m2.order_id = p_order_id
        and m2.type = 'consumption'
      order by m2.created_at desc
      limit 1
    ),
    -- Subconsulta y no un agregado: `min()` no existe para uuid. Todas las
    -- líneas de consumo de una orden son de la MISMA mesa, así que cualquiera
    -- sirve.
    'table_id', (
      select m3.table_id
      from public.table_deposit_movements m3
      where m3.order_id = p_order_id
        and m3.type = 'consumption'
      limit 1
    )
  )
  from public.table_deposit_movements m
  where m.order_id = p_order_id
    and m.type = 'consumption'
    and public.user_has_business_access(auth.uid(), m.business_id);
$$;

grant execute on function public.fn_ensure_table_deposit_method(uuid) to authenticated;
grant execute on function public.fn_table_deposit_account(uuid, boolean) to authenticated;
grant execute on function public.fn_table_deposit_add(uuid, numeric, text, uuid, text, text, text) to authenticated;
grant execute on function public.fn_table_deposit_refund(uuid, numeric, uuid, text) to authenticated;
grant execute on function public.fn_table_deposit_transfer(uuid, uuid, numeric, text) to authenticated;
grant execute on function public.fn_table_deposit_balances(uuid) to authenticated;
grant execute on function public.fn_table_deposit_balance_for_order(uuid) to authenticated;
grant execute on function public.fn_table_deposit_for_payment(uuid) to authenticated;
grant execute on function public.fn_table_deposit_for_order(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. Permisos
-- ---------------------------------------------------------------------------
-- Sin la fila en el catálogo, el join del RPC de permisos lo descarta EN
-- SILENCIO y el gate no pega nunca ([[project_permission_codes_missing_in_db_catalog]]).

insert into public.permissions (code, name, module, description) values
  ('ventas.abono_mesa.ver',
   'Ver saldo de mesa',
   'operations',
   'Ve el saldo prepagado de las mesas y su historial de movimientos.'),
  ('ventas.abono_mesa.registrar',
   'Registrar abono de mesa',
   'operations',
   'Registra un abono prepagado a una mesa. El dinero entra a la caja en ese momento.'),
  ('ventas.abono_mesa.devolver',
   'Devolver o mover saldo de mesa',
   'operations',
   'Devuelve en efectivo el saldo no consumido de una mesa o lo transfiere a otra mesa. Saca dinero de la caja.')
on conflict (code) do update
  set name        = excluded.name,
      module      = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) in ('owner', 'admin', 'manager', 'cashier')
  and p.code in ('ventas.abono_mesa.ver', 'ventas.abono_mesa.registrar')
on conflict (role_id, permission_id) do nothing;

-- Devolver/mover saldo saca plata de la caja: solo dueño, admin y gerente.
insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) in ('owner', 'admin', 'manager')
  and p.code = 'ventas.abono_mesa.devolver'
on conflict (role_id, permission_id) do nothing;

commit;

-- =============================================================================
-- VERIFICACIÓN (correr después de aplicar)
--
--   -- 1. Tablas, trigger y método creados
--   select
--     (select count(*) from information_schema.tables
--       where table_schema = 'public'
--         and table_name in ('table_deposit_accounts','table_deposit_movements')) as tablas,      -- 2
--     (select count(*) from pg_trigger
--       where tgname in ('trg_table_deposit_on_payment','trg_table_deposit_on_payment_void')) as triggers, -- 2
--     (select count(*) from public.payment_methods where code = 'table_deposit') as metodos,      -- 1 por negocio
--     (select count(*) from public.permissions where code like 'ventas.abono_mesa.%') as permisos; -- 3
--
--   -- 2. Prueba de punta a punta en un negocio de prueba (NO en producción):
--   --    abonar 10,000 → cobrar 1,000 → el saldo tiene que quedar en 9,000.
--   select public.fn_table_deposit_add(
--     '<table_id>'::uuid, 10000, 'cash', '<cash_session_id>'::uuid,
--     null, 'Juan Pérez', 'prueba');
--   select table_id, balance from public.fn_table_deposit_balances('<business_id>'::uuid);
-- =============================================================================
