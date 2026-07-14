-- =============================================================================
-- Módulo de Créditos: venta a crédito (CxC) + cuentas por pagar (CxP).
--
-- CONTEXTO:
--   Las tablas `customer_credits` y `credit_payments` existen desde el dump
--   base pero están dormidas: sin RPCs, sin triggers, sin uso en la app.
--   No existe ningún concepto financiero del lado de compras (purchase_orders
--   solo tiene estado logístico). Este cambio activa ambos lados:
--
--   CxC (cuentas por cobrar):
--     - `customers` gana credit_enabled / credit_limit / credit_days.
--     - Método de pago `code='credit'` sembrado por negocio (el modal de
--       cobro es data-driven sobre payment_methods; fn_process_payment_v3
--       ya resuelve por code y NO genera cash_transactions para códigos
--       distintos de 'cash', así que el crédito no infla la caja).
--     - Trigger sobre `payments`: cobro con método credit → crea la cuenta
--       por cobrar en customer_credits (backstop de cliente obligatorio,
--       crédito habilitado y límite).
--     - RPC `fn_register_credit_abono`: abono a un crédito; si el abono es
--       en efectivo entra a la caja abierta como 'deposit'.
--
--   CxP (cuentas por pagar):
--     - Tablas nuevas `supplier_credits` + `supplier_credit_payments`,
--       espejo de customer_credits/credit_payments.
--     - RPC `fn_register_supplier_credit_payment`: pago/abono a proveedor;
--       si sale en efectivo de una caja abierta se registra como 'expense'.
--     - La creación de la CxP la hace la app (compra a crédito en el
--       registro de compras, o alta manual) vía RLS owner/admin/manager.
--
--   NO se toca fn_process_payment_v3 (fiscal, la BD viva diverge del repo).
--   El estado 'overdue' se deriva en la app (due_date < hoy y balance > 0);
--   en BD solo se persisten pending/partial/paid/cancelled.
--
-- IDEMPOTENTE: IF NOT EXISTS / CREATE OR REPLACE / DROP IF EXISTS.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Clientes: campos de crédito formales (antes iban como texto en notes)
-- ---------------------------------------------------------------------------

alter table public.customers
  add column if not exists credit_enabled boolean not null default false,
  add column if not exists credit_limit numeric,
  add column if not exists credit_days integer;

comment on column public.customers.credit_enabled is
  'Permite venderle a crédito (fiao). Gate del botón Crédito en el cobro.';
comment on column public.customers.credit_limit is
  'Límite de deuda viva en CxC. NULL/0 = sin límite.';
comment on column public.customers.credit_days is
  'Plazo default en días para due_date de nuevos créditos. NULL = sin fecha.';

-- ---------------------------------------------------------------------------
-- 2. Método de pago 'credit' por negocio
--    Seed para negocios existentes + helper para negocios nuevos (la app lo
--    llama best-effort al abrir el cobro con permiso de crédito). No se toca
--    create_business_defaults para no divergir de la BD viva.
-- ---------------------------------------------------------------------------

create or replace function public.fn_ensure_credit_payment_method(p_business_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_business_id is null then
    raise exception 'BUSINESS_REQUIRED';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  select pm.id into v_id
  from public.payment_methods pm
  where pm.business_id = p_business_id and pm.code = 'credit'
  limit 1;

  if v_id is null then
    insert into public.payment_methods(business_id, name, code, is_active, requires_reference, position)
    values (p_business_id, 'Crédito', 'credit', true, false, 90)
    returning id into v_id;
  end if;

  return v_id;
end;
$$;

insert into public.payment_methods (business_id, name, code, is_active, requires_reference, position)
select b.id, 'Crédito', 'credit', true, false, 90
from public.businesses b
where not exists (
  select 1 from public.payment_methods pm
  where pm.business_id = b.id and pm.code = 'credit'
);

-- ---------------------------------------------------------------------------
-- 3. CxC: índices + policies de escritura administrativa
-- ---------------------------------------------------------------------------

create index if not exists idx_customer_credits_business_status
  on public.customer_credits (business_id, status, due_date);

create index if not exists idx_customer_credits_customer
  on public.customer_credits (customer_id);

create index if not exists idx_credit_payments_credit
  on public.credit_payments (credit_id);

-- Owner/admin pueden ajustar una CxC (cancelar, mover vencimiento, notas).
-- Los inserts/abonos van por trigger y RPC security definer.
drop policy if exists "cc_admin_update" on public.customer_credits;
create policy "cc_admin_update" on public.customer_credits
  for update to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin'])
  );

-- ---------------------------------------------------------------------------
-- 4. CxC: trigger — cobro con método 'credit' crea la cuenta por cobrar
-- ---------------------------------------------------------------------------

create or replace function public.fn_payment_create_customer_credit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method_code text;
  v_customer record;
  v_amount numeric;
  v_open_balance numeric;
  v_due date;
begin
  if new.status <> 'completed' then
    return new;
  end if;

  select pm.code into v_method_code
  from public.payment_methods pm
  where pm.id = new.payment_method_id;

  if coalesce(v_method_code, '') <> 'credit' then
    return new;
  end if;

  v_amount := coalesce(new.amount, 0) - coalesce(new.change_amount, 0);
  if v_amount <= 0 then
    return new;
  end if;

  -- Backstops (la app valida primero y muestra mensajes amigables).
  if new.customer_id is null then
    raise exception 'CREDIT_CUSTOMER_REQUIRED';
  end if;

  select c.id, c.credit_enabled, c.credit_limit, c.credit_days
    into v_customer
  from public.customers c
  where c.id = new.customer_id
    and c.business_id = new.business_id;

  if v_customer.id is null then
    raise exception 'CREDIT_CUSTOMER_NOT_FOUND';
  end if;
  if not coalesce(v_customer.credit_enabled, false) then
    raise exception 'CREDIT_NOT_ENABLED_FOR_CUSTOMER';
  end if;

  if coalesce(v_customer.credit_limit, 0) > 0 then
    select coalesce(sum(cc.balance), 0)
      into v_open_balance
    from public.customer_credits cc
    where cc.customer_id = new.customer_id
      and cc.business_id = new.business_id
      and cc.status in ('pending','partial','overdue');

    if v_open_balance + v_amount > v_customer.credit_limit then
      raise exception 'CREDIT_LIMIT_EXCEEDED: deuda % + venta % supera límite %',
        round(v_open_balance, 2), round(v_amount, 2), round(v_customer.credit_limit, 2);
    end if;
  end if;

  if coalesce(v_customer.credit_days, 0) > 0 then
    v_due := (new.created_at at time zone 'America/Santo_Domingo')::date
             + v_customer.credit_days;
  end if;

  insert into public.customer_credits(
    business_id, customer_id, order_id, fiscal_document_id,
    original_amount, balance, due_date, status, notes, created_by, created_at
  )
  values (
    new.business_id, new.customer_id, new.order_id, new.fiscal_document_id,
    round(v_amount, 2), round(v_amount, 2), v_due, 'pending',
    'Venta a crédito', new.processed_by, new.created_at
  );

  return new;
end;
$$;

drop trigger if exists trg_payment_create_customer_credit on public.payments;
create trigger trg_payment_create_customer_credit
  after insert on public.payments
  for each row
  execute function public.fn_payment_create_customer_credit();

comment on trigger trg_payment_create_customer_credit on public.payments is
  'Cobro con método credit → crea la cuenta por cobrar en customer_credits.';

-- ---------------------------------------------------------------------------
-- 5. CxC: abono
-- ---------------------------------------------------------------------------

create or replace function public.fn_register_credit_abono(
  p_credit_id uuid,
  p_amount numeric,
  p_payment_method_code text default 'cash',
  p_reference text default null,
  p_session_id uuid default null
)
returns public.customer_credits
language plpgsql
security definer
set search_path = public
as $$
declare
  v_credit public.customer_credits;
  v_method_id uuid;
  v_method_code text;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'ABONO_AMOUNT_INVALID';
  end if;

  select * into v_credit
  from public.customer_credits
  where id = p_credit_id
  for update;

  if v_credit.id is null then
    raise exception 'CREDIT_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_credit.business_id) then
    raise exception 'ACCESS_DENIED';
  end if;
  if v_credit.status in ('paid','cancelled') then
    raise exception 'CREDIT_ALREADY_CLOSED';
  end if;
  if p_amount > v_credit.balance + 0.01 then
    raise exception 'ABONO_EXCEEDS_BALANCE: abono % > saldo %',
      round(p_amount, 2), round(v_credit.balance, 2);
  end if;

  v_method_code := lower(coalesce(nullif(trim(p_payment_method_code), ''), 'cash'));

  select pm.id into v_method_id
  from public.payment_methods pm
  where pm.business_id = v_credit.business_id
    and pm.code = v_method_code
  limit 1;

  -- Abono en efectivo entra a la caja abierta como depósito.
  if v_method_code = 'cash' then
    if p_session_id is null then
      raise exception 'CASH_SESSION_REQUIRED';
    end if;
    if not exists (
      select 1 from public.cash_register_sessions cs
      where cs.id = p_session_id
        and cs.status = 'open'
        and cs.closed_at is null
    ) then
      raise exception 'CASH_SESSION_NOT_OPEN';
    end if;

    insert into public.cash_transactions(session_id, amount, type, description, related_order_id)
    values (
      p_session_id, round(least(p_amount, v_credit.balance), 2), 'deposit',
      'Abono crédito CxC ' || left(v_credit.id::text, 8), v_credit.order_id
    );
  end if;

  insert into public.credit_payments(credit_id, amount, payment_method_id, reference, received_by, session_id)
  values (v_credit.id, round(least(p_amount, v_credit.balance), 2), v_method_id,
          nullif(trim(coalesce(p_reference, '')), ''), auth.uid(), p_session_id);

  update public.customer_credits
     set balance = greatest(round(balance - p_amount, 2), 0),
         status  = case when round(balance - p_amount, 2) <= 0 then 'paid' else 'partial' end
   where id = v_credit.id
   returning * into v_credit;

  return v_credit;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. CxP: tablas espejo
-- ---------------------------------------------------------------------------

create table if not exists public.supplier_credits (
  id                 uuid not null default gen_random_uuid() primary key,
  business_id        uuid not null references public.businesses(id) on delete cascade,
  supplier_id        uuid not null references public.suppliers(id),
  purchase_order_id  uuid references public.purchase_orders(id),
  invoice_number     text,
  original_amount    numeric not null check (original_amount > 0),
  balance            numeric not null,
  due_date           date,
  status             text not null default 'pending'
                       check (status in ('pending','partial','paid','overdue','cancelled')),
  notes              text,
  created_by         uuid references auth.users(id),
  created_at         timestamptz not null default now()
);

create index if not exists idx_supplier_credits_business_status
  on public.supplier_credits (business_id, status, due_date);

create index if not exists idx_supplier_credits_supplier
  on public.supplier_credits (supplier_id);

alter table public.supplier_credits enable row level security;

drop policy if exists "sc_select" on public.supplier_credits;
create policy "sc_select" on public.supplier_credits
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "sc_write" on public.supplier_credits;
create policy "sc_write" on public.supplier_credits
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

create table if not exists public.supplier_credit_payments (
  id                  uuid not null default gen_random_uuid() primary key,
  supplier_credit_id  uuid not null references public.supplier_credits(id) on delete cascade,
  amount              numeric not null check (amount > 0),
  payment_method_code text,
  reference           text,
  paid_by             uuid references auth.users(id),
  session_id          uuid references public.cash_register_sessions(id),
  created_at          timestamptz not null default now()
);

create index if not exists idx_supplier_credit_payments_parent
  on public.supplier_credit_payments (supplier_credit_id);

alter table public.supplier_credit_payments enable row level security;

drop policy if exists "scp_select" on public.supplier_credit_payments;
create policy "scp_select" on public.supplier_credit_payments
  for select to authenticated
  using (
    exists (
      select 1 from public.supplier_credits sc
      where sc.id = supplier_credit_payments.supplier_credit_id
        and public.user_has_business_access(auth.uid(), sc.business_id)
    )
  );

-- ---------------------------------------------------------------------------
-- 7. CxP: pago/abono a proveedor
-- ---------------------------------------------------------------------------

create or replace function public.fn_register_supplier_credit_payment(
  p_credit_id uuid,
  p_amount numeric,
  p_payment_method_code text default 'cash',
  p_reference text default null,
  p_session_id uuid default null
)
returns public.supplier_credits
language plpgsql
security definer
set search_path = public
as $$
declare
  v_credit public.supplier_credits;
  v_method_code text;
  v_supplier_name text;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'ABONO_AMOUNT_INVALID';
  end if;

  select * into v_credit
  from public.supplier_credits
  where id = p_credit_id
  for update;

  if v_credit.id is null then
    raise exception 'CREDIT_NOT_FOUND';
  end if;
  if coalesce(public.user_business_role(auth.uid(), v_credit.business_id), '')
       not in ('owner','admin','manager') then
    raise exception 'ACCESS_DENIED';
  end if;
  if v_credit.status in ('paid','cancelled') then
    raise exception 'CREDIT_ALREADY_CLOSED';
  end if;
  if p_amount > v_credit.balance + 0.01 then
    raise exception 'ABONO_EXCEEDS_BALANCE: abono % > saldo %',
      round(p_amount, 2), round(v_credit.balance, 2);
  end if;

  v_method_code := lower(coalesce(nullif(trim(p_payment_method_code), ''), 'cash'));

  -- Pago en efectivo desde una caja abierta sale como gasto.
  if v_method_code = 'cash' and p_session_id is not null then
    if not exists (
      select 1 from public.cash_register_sessions cs
      where cs.id = p_session_id
        and cs.status = 'open'
        and cs.closed_at is null
    ) then
      raise exception 'CASH_SESSION_NOT_OPEN';
    end if;

    select s.name into v_supplier_name
    from public.suppliers s
    where s.id = v_credit.supplier_id;

    insert into public.cash_transactions(session_id, amount, type, description)
    values (
      p_session_id, round(least(p_amount, v_credit.balance), 2), 'expense',
      'Pago CxP ' || coalesce(v_supplier_name, left(v_credit.id::text, 8))
    );
  end if;

  insert into public.supplier_credit_payments(
    supplier_credit_id, amount, payment_method_code, reference, paid_by, session_id
  )
  values (
    v_credit.id, round(least(p_amount, v_credit.balance), 2), v_method_code,
    nullif(trim(coalesce(p_reference, '')), ''), auth.uid(), p_session_id
  );

  update public.supplier_credits
     set balance = greatest(round(balance - p_amount, 2), 0),
         status  = case when round(balance - p_amount, 2) <= 0 then 'paid' else 'partial' end
   where id = v_credit.id
   returning * into v_credit;

  return v_credit;
end;
$$;

commit;
