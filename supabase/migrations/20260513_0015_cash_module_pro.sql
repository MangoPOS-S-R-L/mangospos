-- =============================================================================
-- Sprint Caja Profesional — Fase A: estabilización.
--
-- ENTREGA:
--   1. Auto-cierre de sesiones zombi (>3 días sin cerrar).
--      Las cerramos con status='closed', end_amount=NULL,
--      difference=NULL, notes='AUTO_CLOSED_ZOMBIE'. Quedan auditables
--      y no bloquean nuevas aperturas en su caja/usuario.
--   2. cash_transactions.reason_code: pointer al catálogo. Opcional
--      en el schema (legacy data sin razón sigue válida) pero la UI
--      lo va a exigir en altas nuevas (Fase C).
--   3. cash_transactions.created_by + approved_by: trazabilidad de
--      quién metió/autorizó el movimiento.
--   4. Tabla `cash_transaction_reasons`: catálogo configurable por
--      negocio. Sembrada con razones default al crear el negocio
--      (cubre los casos típicos: vuelto, traslado bóveda, compra
--      menor, ajuste, otro).
--   5. fn_cash_transaction_create: RPC que centraliza la creación
--      de movimientos manuales con validación (sesión abierta,
--      razón válida, créditos no negativos).
--   6. Vista v_cash_sessions_health: ranking de sesiones abiertas
--      con saldo esperado vivo, edad y "needs_attention".
--
-- BACKWARDS-COMPATIBLE:
--   - reason_code es nullable → transacciones legacy intactas.
--   - cash_transactions.created_by + approved_by nullables.
--   - El INSERT directo a cash_transactions sigue funcionando para
--     compatibilidad con código existente (sales, process_payment_v3).
--     La validación nueva solo aplica vía la nueva RPC.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Auto-cierre de zombis (>3 días).
--
-- Closing them with end_amount=NULL evita que el sistema asuma una
-- diferencia (no contamos lo que no se contó). El cierre formal
-- "real" lo puede hacer un admin desde el dashboard si quiere ajustar.
-- ---------------------------------------------------------------------------

do $$
declare
  v_count integer;
begin
  with closed_zombies as (
    update public.cash_register_sessions s
    set status = 'closed',
        closed_at = now(),
        end_amount = null,
        difference = null,
        notes = coalesce(notes, '') ||
                ' [AUTO_CLOSED_ZOMBIE: session >3d sin cerrar al 2026-05-13]'
    where s.status = 'open'
      and s.opened_at < now() - interval '3 days'
    returning s.id
  )
  select count(*) into v_count from closed_zombies;
  raise notice 'Auto-cerradas % sesion(es) zombi (>3 dias).', v_count;
end$$;

-- ---------------------------------------------------------------------------
-- 2. Catálogo de razones (configurable por negocio).
-- ---------------------------------------------------------------------------

create table if not exists public.cash_transaction_reasons (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  code text not null,
  label text not null,
  -- Para qué tipo aplica la razón. NULL = aplica a todos.
  applies_to text check (applies_to in ('deposit', 'withdrawal', 'expense', null)),
  is_active boolean default true not null,
  -- requires_pin: si true, este tipo de movimiento siempre requiere
  -- PIN supervisor (independiente del umbral monetario). Útil para
  -- razones sensibles tipo "ajuste de caja" o "pago en efectivo
  -- fuera de proveedor".
  requires_pin boolean default false not null,
  created_at timestamptz default now() not null,
  unique (business_id, code)
);

create index if not exists idx_cash_reasons_business
  on public.cash_transaction_reasons (business_id, is_active);

comment on table public.cash_transaction_reasons is
  'Catálogo de razones para movimientos manuales de caja (deposit/'
  'withdrawal/expense). Cada negocio tiene su propio set. La UI '
  'obliga a elegir una al crear el movimiento.';

-- Sembrar defaults para todos los negocios existentes que no tengan
-- razones aún. Idempotente vía ON CONFLICT DO NOTHING.
insert into public.cash_transaction_reasons
  (business_id, code, label, applies_to, requires_pin)
select b.id, r.code, r.label, r.applies_to, r.requires_pin
from public.businesses b
cross join (values
  -- Depósitos
  ('change_bank',       'Cambio para vuelto',          'deposit'::text,    false),
  ('initial_top_up',    'Refuerzo inicial',            'deposit',          false),
  ('manager_deposit',   'Depósito de gerencia',        'deposit',          true),
  -- Retiros
  ('safe_deposit',      'Traslado a bóveda',           'withdrawal',       false),
  ('bank_drop',         'Depósito al banco',           'withdrawal',       true),
  ('change_withdrawal', 'Retiro de vuelto sobrante',   'withdrawal',       false),
  ('shift_change',      'Entrega de turno',            'withdrawal',       false),
  -- Gastos
  ('supplier_cash',     'Pago a proveedor en efectivo','expense',          true),
  ('petty_cash',        'Compra menor / caja chica',   'expense',          false),
  ('repair_supplies',   'Reparación o suministros',    'expense',          false),
  ('staff_advance',     'Adelanto a empleado',         'expense',          true),
  -- Universales
  ('cash_count_adjust', 'Ajuste por conteo',           null::text,         true),
  ('other',             'Otro (especificar)',          null,               false)
) as r(code, label, applies_to, requires_pin)
on conflict (business_id, code) do nothing;

-- RLS: cualquier miembro del business puede leer; solo admin/owner edita.
alter table public.cash_transaction_reasons enable row level security;

drop policy if exists cash_reasons_select on public.cash_transaction_reasons;
create policy cash_reasons_select
  on public.cash_transaction_reasons
  for select
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists cash_reasons_modify on public.cash_transaction_reasons;
create policy cash_reasons_modify
  on public.cash_transaction_reasons
  for all
  using (
    public.user_business_role(auth.uid(), business_id) in ('owner', 'admin', 'manager')
  )
  with check (
    public.user_business_role(auth.uid(), business_id) in ('owner', 'admin', 'manager')
  );

-- ---------------------------------------------------------------------------
-- 3. Columnas nuevas en cash_transactions.
-- ---------------------------------------------------------------------------

alter table public.cash_transactions
  add column if not exists reason_code text;

alter table public.cash_transactions
  add column if not exists reason_id uuid references public.cash_transaction_reasons(id) on delete set null;

alter table public.cash_transactions
  add column if not exists created_by uuid;

alter table public.cash_transactions
  add column if not exists approved_by uuid;

alter table public.cash_transactions
  add column if not exists approval_pin_used boolean default false not null;

create index if not exists idx_cash_tx_reason
  on public.cash_transactions (reason_id)
  where reason_id is not null;

comment on column public.cash_transactions.reason_code is
  'Code denormalizado del cash_transaction_reasons (para reportes '
  'rápidos sin join). Validado por la UI/RPC al insertar.';

comment on column public.cash_transactions.created_by is
  'Usuario que registró el movimiento. NULL solo para legacy.';

comment on column public.cash_transactions.approved_by is
  'Supervisor que aprobó (con PIN). NULL si no requirió aprobación.';

-- ---------------------------------------------------------------------------
-- 4. RPC unificada para crear movimientos manuales con validación.
--
-- El cliente Dart llama esta función en lugar de hacer INSERT directo.
-- Centraliza:
--   - Verifica que la sesión esté abierta.
--   - Verifica que reason_code exista en el catálogo del negocio.
--   - Si el monto excede el umbral del negocio o la razón exige PIN,
--     requiere `p_approved_by` (sino raise).
--   - Inserta con created_by + approved_by + reason metadata.
-- ---------------------------------------------------------------------------

create or replace function public.fn_cash_transaction_create(
  p_session_id uuid,
  p_type text,
  p_amount numeric,
  p_reason_code text,
  p_description text default null,
  p_created_by uuid default null,
  p_approved_by uuid default null
)
returns public.cash_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.cash_register_sessions;
  v_reason public.cash_transaction_reasons;
  v_business_id uuid;
  v_threshold numeric;
  v_result public.cash_transactions;
  v_needs_pin boolean;
begin
  if p_session_id is null then
    raise exception 'SESSION_ID_REQUIRED';
  end if;
  if p_type not in ('deposit', 'withdrawal', 'expense') then
    raise exception 'INVALID_TYPE: % (solo deposit/withdrawal/expense)', p_type;
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE';
  end if;
  if p_reason_code is null or btrim(p_reason_code) = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  -- Sesión debe estar abierta.
  select * into v_session
  from public.cash_register_sessions
  where id = p_session_id
  for update;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;
  if v_session.status <> 'open' then
    raise exception 'SESSION_NOT_OPEN: status=%', v_session.status;
  end if;

  -- Business_id del register para validar la razón.
  select business_id into v_business_id
  from public.cash_registers
  where id = v_session.cash_register_id;

  -- Buscar la razón en el catálogo. Si no existe, lanzar.
  select * into v_reason
  from public.cash_transaction_reasons
  where business_id = v_business_id
    and code = p_reason_code
    and is_active = true;

  if not found then
    raise exception 'REASON_NOT_FOUND: % no es una razón válida para este negocio', p_reason_code;
  end if;

  -- Validar que la razón aplique al tipo de movimiento.
  if v_reason.applies_to is not null and v_reason.applies_to <> p_type then
    raise exception 'REASON_WRONG_TYPE: razón "%" aplica a %, no a %',
      v_reason.code, v_reason.applies_to, p_type;
  end if;

  -- Determinar si se exige PIN supervisor.
  select coalesce(cash_movement_pin_threshold, 0) into v_threshold
  from public.business_settings
  where business_id = v_business_id;
  v_threshold := coalesce(v_threshold, 0);

  v_needs_pin :=
    v_reason.requires_pin
    or (v_threshold > 0 and p_amount >= v_threshold);

  if v_needs_pin and p_approved_by is null then
    raise exception 'APPROVAL_REQUIRED: este movimiento requiere PIN de supervisor';
  end if;

  -- Insert final.
  insert into public.cash_transactions (
    session_id,
    type,
    amount,
    description,
    reason_code,
    reason_id,
    created_by,
    approved_by,
    approval_pin_used
  ) values (
    p_session_id,
    p_type,
    p_amount,
    p_description,
    v_reason.code,
    v_reason.id,
    p_created_by,
    p_approved_by,
    v_needs_pin
  )
  returning * into v_result;

  return v_result;
end;
$$;

grant execute on function public.fn_cash_transaction_create(
  uuid, text, numeric, text, text, uuid, uuid
) to authenticated;

-- Umbral monetario que dispara PIN supervisor. Sembrar columna; el
-- admin la configura en Ajustes → Modos de negocio (UI viene después).
alter table public.business_settings
  add column if not exists cash_movement_pin_threshold numeric default 0 not null;

comment on column public.business_settings.cash_movement_pin_threshold is
  'Monto desde el cual un retiro/depósito/gasto requiere PIN de '
  'supervisor. 0 = sin umbral por monto (solo razones marcadas '
  'requires_pin lo piden).';

-- ---------------------------------------------------------------------------
-- 5. Vista de salud de sesiones (para dashboard Sprint 5 futuro).
-- ---------------------------------------------------------------------------

create or replace view public.v_cash_sessions_health as
select
  s.id                                       as session_id,
  cr.business_id,
  cr.id                                      as cash_register_id,
  cr.name                                    as caja_nombre,
  s.user_id,
  s.opened_at,
  s.closed_at,
  s.status,
  age(coalesce(s.closed_at, now()), s.opened_at) as duracion,
  s.start_amount,
  coalesce((
    select sum(amount) from public.cash_transactions
    where session_id = s.id and type = 'sale'
  ), 0) as ventas_efectivo,
  coalesce((
    select sum(amount) from public.cash_transactions
    where session_id = s.id and type = 'deposit'
  ), 0) as depositos,
  coalesce((
    select sum(amount) from public.cash_transactions
    where session_id = s.id and type = 'withdrawal'
  ), 0) as retiros,
  coalesce((
    select sum(amount) from public.cash_transactions
    where session_id = s.id and type = 'expense'
  ), 0) as gastos,
  (
    s.start_amount
    + coalesce((select sum(amount) from public.cash_transactions where session_id = s.id and type = 'sale'), 0)
    + coalesce((select sum(amount) from public.cash_transactions where session_id = s.id and type = 'deposit'), 0)
    - coalesce((select sum(amount) from public.cash_transactions where session_id = s.id and type = 'withdrawal'), 0)
    - coalesce((select sum(amount) from public.cash_transactions where session_id = s.id and type = 'expense'), 0)
  ) as saldo_esperado_actual,
  -- Bandera: necesita atención del admin.
  case
    when s.status = 'open'
         and s.opened_at < now() - interval '12 hours'
      then true
    else false
  end as needs_attention
from public.cash_register_sessions s
join public.cash_registers cr on cr.id = s.cash_register_id;

comment on view public.v_cash_sessions_health is
  'Health check de sesiones de caja: saldo vivo + bandera de needs_attention '
  'para sesiones abiertas >12h. Lo consume el dashboard del admin.';

commit;
