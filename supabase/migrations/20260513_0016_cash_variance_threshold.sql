-- =============================================================================
-- Sprint Caja Profesional — Fase D (deudas).
--
-- ENTREGA:
--   1. business_settings.cash_variance_alert_threshold: umbral
--      monetario desde el cual al cerrar caja se muestra alerta
--      especial y se loguea el cierre como "with_variance".
--   2. fn_force_close_cash_session: RPC para que un manager cierre
--      una sesión que NO es suya (cajero ausente, turno terminado
--      sin cerrar). El monto contado puede ser 0 si no se hizo
--      arqueo físico. Queda flag de auditoría.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Umbral de varianza. 0 = sin umbral (no se alerta nunca).
-- ---------------------------------------------------------------------------

alter table public.business_settings
  add column if not exists cash_variance_alert_threshold numeric default 0 not null;

comment on column public.business_settings.cash_variance_alert_threshold is
  'Si la diferencia absoluta al cerrar caja excede este umbral, la UI '
  'muestra alerta de varianza y el cierre se loguea con bandera para '
  'revisión del admin. 0 = sin umbral.';

-- ---------------------------------------------------------------------------
-- 2. Columna opcional para flag de varianza en sesiones cerradas.
--    Útil para reportes y para el dashboard de salud.
-- ---------------------------------------------------------------------------

alter table public.cash_register_sessions
  add column if not exists variance_flagged boolean default false not null;

comment on column public.cash_register_sessions.variance_flagged is
  'True si al cerrar la sesión, |difference| excedió el threshold del '
  'negocio. Marcador para que el admin revise.';

-- ---------------------------------------------------------------------------
-- 3. RPC: force-close por manager.
--
-- Casos de uso:
--   - Cajero se fue sin cerrar.
--   - Sesión <3d (no se auto-cerró) pero el negocio quiere cerrar.
--   - Cajero está en otro device y no puede cerrar acá.
--
-- Reglas:
--   - Solo owner/admin/manager pueden ejecutarla.
--   - Marca la sesión `closed`, `closed_at = now()`, con
--     `end_amount = p_end_amount` (puede ser NULL si no se contó).
--   - Si end_amount es NULL → `difference = NULL` (no se sabe).
--   - Si end_amount es numérico → calcula difference normal.
--   - Loguea en `notes` quién forzó el cierre y por qué.
-- ---------------------------------------------------------------------------

create or replace function public.fn_force_close_cash_session(
  p_session_id uuid,
  p_end_amount numeric,
  p_reason text,
  p_forced_by uuid default null
)
returns public.cash_register_sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.cash_register_sessions;
  v_business_id uuid;
  v_role text;
  v_expected_cash numeric := 0;
  v_difference numeric;
  v_start_amount numeric := 0;
  v_total_sales numeric := 0;
  v_total_deposits numeric := 0;
  v_total_withdrawals numeric := 0;
  v_total_expenses numeric := 0;
  v_caller uuid;
begin
  if p_session_id is null then
    raise exception 'SESSION_ID_REQUIRED';
  end if;

  v_caller := coalesce(p_forced_by, auth.uid());
  if v_caller is null then
    raise exception 'CALLER_REQUIRED';
  end if;

  -- Lock + leer.
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

  -- Verificar que el caller sea owner/admin/manager del business.
  select business_id into v_business_id
  from public.cash_registers
  where id = v_session.cash_register_id;
  v_role := public.user_business_role(v_caller, v_business_id);
  if v_role not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE: % no puede forzar cierre', v_role;
  end if;

  -- Calcular esperado (igual que fn_close_cash_session).
  v_start_amount := coalesce(v_session.start_amount, 0);
  select coalesce(sum(amount), 0) into v_total_sales
  from public.cash_transactions
  where session_id = p_session_id and type = 'sale';
  select coalesce(sum(amount), 0) into v_total_deposits
  from public.cash_transactions
  where session_id = p_session_id and type = 'deposit';
  select coalesce(sum(amount), 0) into v_total_withdrawals
  from public.cash_transactions
  where session_id = p_session_id and type = 'withdrawal';
  select coalesce(sum(amount), 0) into v_total_expenses
  from public.cash_transactions
  where session_id = p_session_id and type = 'expense';
  v_expected_cash := v_start_amount + v_total_sales + v_total_deposits
                     - v_total_withdrawals - v_total_expenses;

  if p_end_amount is null then
    v_difference := null;
  else
    v_difference := p_end_amount - v_expected_cash;
  end if;

  update public.cash_register_sessions
  set status = 'closed',
      closed_at = now(),
      end_amount = p_end_amount,
      difference = v_difference,
      notes = coalesce(notes, '') ||
              format(' [FORCE_CLOSED by %s on %s: %s]',
                     v_caller::text,
                     to_char(now(), 'YYYY-MM-DD HH24:MI'),
                     coalesce(p_reason, 'sin razón'))
  where id = p_session_id
  returning * into v_session;

  return v_session;
end;
$$;

grant execute on function public.fn_force_close_cash_session(uuid, numeric, text, uuid)
  to authenticated;

comment on function public.fn_force_close_cash_session(uuid, numeric, text, uuid) is
  'Cierre forzado por manager/admin/owner de una sesión abierta que '
  'no es propia (cajero ausente, turno terminado, etc.). Audita en '
  'notes quién lo hizo y por qué.';

commit;
