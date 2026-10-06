-- =============================================================================
-- 20261005_0002 — Pasar una caja abierta a otro equipo ("caja pegada")
-- =============================================================================
--
-- REGLA DEL NEGOCIO (dueño, 2026-10-05): la caja es del EQUIPO y la
-- registradora donde se abrió. Un cajero/mesero solo cobra con la caja de su
-- equipo; dueño/admin desde cualquiera. La app ya lo aplica (ver
-- CashierRepository.resolveDeviceCash / pickChargeSession).
--
-- PROBLEMA QUE RESUELVE
-- ─────────────────────
-- Si el equipo de la caja se apaga, se daña o se reinstala la app (cambia el
-- device_id), la caja queda abierta "en otro equipo" y nadie puede cobrar con
-- ella ni abrir otra. Antes la salida era un script SQL de soporte.
--
-- QUÉ HACE
-- ────────
-- `fn_move_cash_session_to_device(p_session_id, p_device_id, p_device_name,
-- p_approver_pin)` cambia el device_id de la sesión al equipo que llama. El
-- arqueo no cambia (mismas ventas, mismo fondo, mismo dueño de la sesión); el
-- equipo viejo deja de poder cobrar con ella.
--
-- AUTORIZACIÓN (en el server, no solo en la app):
-- - La cuenta logueada debe pertenecer al negocio de la caja.
-- - Si su rol es owner/admin/manager, basta con eso.
-- - Si no, exige `p_approver_pin`: se valida con fn_verify_employee_pin y el
--   rol del aprobador (user_business_role, que sí reconoce al dueño por
--   businesses.owner_id) debe ser owner/admin/manager.
--
-- REGLA POR EQUIPO: el equipo destino no puede tener otra caja abierta
-- (global si el dueño de la sesión es personal; solo en ese negocio si es
-- dueño/admin), igual que fn_open_cash_session (20261005_0001). Mismos
-- advisory locks y mismo orden (negocio → usuario → equipo).
--
-- Rastro en audit_logs (tolerante: si la tabla difiere, no tumba el cambio).
-- =============================================================================

begin;

create or replace function public.fn_move_cash_session_to_device(
  p_session_id uuid,
  p_device_id text,
  p_device_name text default null,
  p_approver_pin text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_device text;
  v_session_user uuid;
  v_previous_device text;
  v_status text;
  v_closed_at timestamptz;
  v_business uuid;
  v_caller_role text;
  v_approver jsonb;
  v_approver_user uuid;
  v_approver_role text;
  v_owner_is_admin boolean;
  v_conflict uuid;
  v_conflict_business uuid;
begin
  if v_uid is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'AUTH_REQUIRED',
      'error', 'Debes estar autenticado para pasar una caja.'
    );
  end if;

  if p_session_id is null then
    return jsonb_build_object('success', false, 'error_code', 'SESSION_NOT_FOUND',
      'error', 'No se indicó la caja.');
  end if;

  if p_device_id is null or btrim(p_device_id) = '' then
    return jsonb_build_object('success', false, 'error_code', 'DEVICE_REQUIRED',
      'error', 'device_id es requerido');
  end if;

  v_device := btrim(p_device_id);

  select s.user_id, cr.business_id
    into v_session_user, v_business
    from public.cash_register_sessions s
    join public.cash_registers cr on cr.id = s.cash_register_id
   where s.id = p_session_id;

  if v_business is null then
    return jsonb_build_object('success', false, 'error_code', 'SESSION_NOT_FOUND',
      'error', 'No se encontró la caja.');
  end if;

  -- ── Autorización ─────────────────────────────────────────────────────
  v_caller_role := public.user_business_role(v_uid, v_business);
  if v_caller_role is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHORIZED',
      'error', 'No tienes acceso a este negocio.');
  end if;

  if v_caller_role not in ('owner', 'admin', 'manager') then
    if p_approver_pin is null or btrim(p_approver_pin) = '' then
      return jsonb_build_object('success', false, 'error_code', 'APPROVAL_REQUIRED',
        'error', 'Se requiere PIN de Supervisor o Administrador.');
    end if;

    v_approver := public.fn_verify_employee_pin(v_business, btrim(p_approver_pin));
    v_approver_user := nullif(v_approver ->> 'user_id', '')::uuid;
    if v_approver_user is not null then
      v_approver_role := public.user_business_role(v_approver_user, v_business);
    end if;

    if v_approver_role is null or v_approver_role not in ('owner', 'admin', 'manager') then
      return jsonb_build_object('success', false, 'error_code', 'APPROVAL_DENIED',
        'error', 'PIN inválido o sin jerarquía de Supervisor/Administrador.');
    end if;
  end if;

  -- ── Serializar con las aperturas (mismo orden que fn_open_cash_session)
  perform pg_advisory_xact_lock(
    hashtextextended('fn_open_cash_session:business:' || v_business::text, 0));
  perform pg_advisory_xact_lock(
    hashtextextended('fn_open_cash_session:user:' || v_session_user::text, 0));
  perform pg_advisory_xact_lock(
    hashtextextended('fn_open_cash_session:device:' || v_device, 0));

  select s.status, s.closed_at, s.device_id
    into v_status, v_closed_at, v_previous_device
    from public.cash_register_sessions s
   where s.id = p_session_id
   for update;

  if v_status is distinct from 'open' or v_closed_at is not null then
    return jsonb_build_object('success', false, 'error_code', 'SESSION_NOT_OPEN',
      'error', 'Esa caja ya no está abierta.');
  end if;

  if v_previous_device is not distinct from v_device then
    return jsonb_build_object('success', true, 'session_id', p_session_id,
      'device_id', v_device, 'previous_device_id', v_previous_device);
  end if;

  -- ── Regla por equipo (según el dueño de la SESIÓN) ───────────────────
  v_owner_is_admin := coalesce(
    public.user_business_role(v_session_user, v_business) in ('owner', 'admin'),
    false
  );

  select s.id, cr.business_id
    into v_conflict, v_conflict_business
    from public.cash_register_sessions s
    left join public.cash_registers cr on cr.id = s.cash_register_id
   where s.device_id = v_device
     and s.id <> p_session_id
     and s.status = 'open'
     and s.closed_at is null
     and (not v_owner_is_admin or cr.business_id = v_business)
   limit 1;

  if v_conflict is not null then
    return jsonb_build_object('success', false, 'error_code', 'DEVICE_ALREADY_OPEN',
      'error', 'Este equipo ya tiene otra caja abierta. Ciérrala antes de pasar esta.',
      'session_id', v_conflict, 'business_id', v_conflict_business);
  end if;

  update public.cash_register_sessions
     set device_id = v_device,
         device_name = coalesce(nullif(btrim(p_device_name), ''), device_name)
   where id = p_session_id;

  begin
    insert into public.audit_logs (business_id, user_id, action, reason, ref_table, ref_id)
    values (
      v_business, v_uid, 'cash_session_moved_to_device',
      format('Caja pasada del equipo %s al equipo %s. Autorizó: %s',
             coalesce(v_previous_device, '(sin equipo)'), v_device,
             coalesce(v_approver_user::text, 'la misma cuenta (' || v_caller_role || ')')),
      'cash_register_sessions', p_session_id
    );
  exception when others then
    raise notice 'fn_move_cash_session_to_device: no se pudo escribir audit_logs (%); el cambio sí se hizo.', sqlerrm;
  end;

  return jsonb_build_object('success', true, 'session_id', p_session_id,
    'device_id', v_device, 'previous_device_id', v_previous_device);
end;
$$;

grant execute on function public.fn_move_cash_session_to_device(uuid, text, text, text)
  to authenticated;

comment on function public.fn_move_cash_session_to_device(uuid, text, text, text) is
  'Pasa una caja abierta al equipo que llama ("caja pegada"). El arqueo no '
  'cambia. Autoriza owner/admin/manager de la cuenta, o un PIN de '
  'supervisor/admin validado en el server. El equipo destino no puede tener '
  'otra caja abierta (global para personal, por negocio para dueño/admin).';

commit;
