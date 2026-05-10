-- PRD · Modos de Cierre de Caja a Ciegas (Compacto vs Detallado)
-- Sub-fase B · Schema cash_count_blind
--
-- Crea:
--   1. Columna `close_mode_used` en cash_register_sessions para audit trail
--      del modo de UX usado al cerrar (compact | detailed). Ambos modos son
--      a ciegas durante el conteo.
--   2. Tabla `cash_count_blind` con desglose firmado del cierre.
--   3. Trigger de inmutabilidad post-firma (rechaza UPDATE/DELETE).
--   4. RLS:
--        - cajero: insert/read sus propios cierres en businesses con acceso
--        - owner/admin/supervisor: read todos los cierres del business
--
-- Nota: la tabla `cash_count_blind` la usan AMBOS modos (compact y detailed)
-- como storage estructurado del desglose firmado. El modal compacto la
-- escribe en un solo paso; el wizard detallado la escribe al firmar el
-- paso 3.
--
-- Naming: el repo usa `cash_register_sessions` (no `cash_sessions`) y
-- `start_amount` (no `opening_float`). En `cash_count_blind` el snapshot
-- semantico se llama `opening_float`; la FK al session usa
-- `cash_register_session_id`.

begin;

-- ============================================================================
-- 1) Audit trail en cash_register_sessions
-- ============================================================================

alter table public.cash_register_sessions
  add column if not exists close_mode_used text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'cash_register_sessions_close_mode_used_check'
      and conrelid = 'public.cash_register_sessions'::regclass
  ) then
    alter table public.cash_register_sessions
      add constraint cash_register_sessions_close_mode_used_check
      check (close_mode_used is null or close_mode_used in ('compact', 'detailed'));
  end if;
end$$;

comment on column public.cash_register_sessions.close_mode_used is
  'Modo de UX con el que se cerro la sesion. NULL = sesion abierta o cerrada antes de PRD blind close. compact | detailed. Ambos son a ciegas durante el conteo. Refleja el modo usado, no el setting actual del business.';

-- ============================================================================
-- 2) Tabla cash_count_blind
-- ============================================================================

create table if not exists public.cash_count_blind (
  id uuid primary key default gen_random_uuid(),
  cash_register_session_id uuid not null
    references public.cash_register_sessions(id) on delete cascade,
  business_id uuid not null references public.businesses(id),

  cash_amount numeric(12, 2) not null check (cash_amount >= 0),
  card_amount numeric(12, 2) not null check (card_amount >= 0),
  transfer_amount numeric(12, 2) not null check (transfer_amount >= 0),

  denominations jsonb not null,

  opening_float numeric(12, 2) not null,

  supervisor_note text,

  signed_at timestamptz not null default now(),
  signed_by_user_id uuid not null references auth.users(id),

  constraint cash_count_blind_session_unique unique (cash_register_session_id)
);

comment on table public.cash_count_blind is
  'Desglose firmado del cierre de caja. Una fila por sesion (UNIQUE en cash_register_session_id). Inmutable post-firma (ver trigger). Usada por ambos modos de cierre (compact y detailed): el cajero cuenta a ciegas y el supervisor compara contra el esperado.';

comment on column public.cash_count_blind.denominations is
  'JSONB con desglose por denominacion. Forma esperada: { "2000": 4, "1000": 9, "500": 6, "200": 7, "100": 5, "50": 8, "coins": 240.00 }.';

comment on column public.cash_count_blind.opening_float is
  'Snapshot del start_amount de la sesion al momento del cierre. Read-only por PRD; no se renombra a start_amount aqui porque opening_float es el nombre semantico del PRD.';

create index if not exists idx_cash_count_blind_business
  on public.cash_count_blind(business_id);
create index if not exists idx_cash_count_blind_signed_at
  on public.cash_count_blind(signed_at desc);

-- ============================================================================
-- 3) Trigger de inmutabilidad post-firma
-- ============================================================================

create or replace function public.reject_cash_count_blind_modifications()
returns trigger
language plpgsql
as $$
begin
  if (tg_op = 'UPDATE' or tg_op = 'DELETE') and old.signed_at is not null then
    raise exception 'cash_count_blind is immutable after signing'
      using errcode = 'P0001';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_cash_count_blind_immutable on public.cash_count_blind;
create trigger trg_cash_count_blind_immutable
  before update or delete on public.cash_count_blind
  for each row execute function public.reject_cash_count_blind_modifications();

-- ============================================================================
-- 4) RLS
-- ============================================================================

alter table public.cash_count_blind enable row level security;

drop policy if exists cash_count_blind_cashier_rw on public.cash_count_blind;
create policy cash_count_blind_cashier_rw on public.cash_count_blind
  for all
  to authenticated
  using (
    public.user_has_business_access(auth.uid(), business_id)
    and signed_by_user_id = auth.uid()
  )
  with check (
    public.user_has_business_access(auth.uid(), business_id)
    and signed_by_user_id = auth.uid()
  );

drop policy if exists cash_count_blind_supervisor_read on public.cash_count_blind;
create policy cash_count_blind_supervisor_read on public.cash_count_blind
  for select
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
    = any (array['owner', 'admin', 'supervisor'])
  );

commit;
