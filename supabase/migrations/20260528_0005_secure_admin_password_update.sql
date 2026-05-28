-- =============================================================================
-- 20260528_0005 — Hardening de admin_update_user_password
-- =============================================================================
--
-- PROBLEMA QUE RESUELVE
-- ─────────────────────
-- La versión previa (20260404_0001) tenía esta configuración crítica:
--
--   - SECURITY DEFINER (corre con privilegios elevados, bypassea RLS)
--   - GRANT EXECUTE TO authenticated (cualquier user autenticado)
--   - SIN validación de rol del caller
--   - SIN validación de que caller y target compartan business
--
-- Resultado: CUALQUIER usuario autenticado (cajero, mesero, cocinero,
-- empleado de otro negocio) podía cambiar la contraseña de CUALQUIER
-- otro user del sistema, incluido el dueño.
--
-- Vectores reales:
--   - Empleado descontento secuestra cuenta del dueño en un click.
--   - Empleado de un negocio cambia pass a usuarios de OTRO negocio.
--   - Atacante con cuenta cajero válida bloquea al dueño y pide rescate.
--
-- FIX
-- ───
-- Cuatro guards en cascada:
--   1. AUTH_REQUIRED  — caller debe tener JWT válido.
--   2. SELF_NOT_ALLOWED — caller NO puede cambiar su propia password
--      por este RPC (debe usar auth.updateUser con re-auth previo,
--      ver MyAccountScreen._openChangePasswordDialog).
--   3. SHARED_BUSINESS_REQUIRED — caller y target deben compartir al
--      menos un business.
--   4. ROLE_REQUIRED — en ESE business compartido, caller debe tener
--      rol 'owner' o 'admin'.
--
-- Validación de password sigue ahí (mínimo 6 chars del fix legacy).
--
-- AUDIT TRAIL (futuro)
-- ────────────────────
-- Esta versión NO graba audit log. Como mejora posterior, podríamos
-- agregar una tabla `auth_admin_actions` que registre: caller_id,
-- target_id, action='reset_password', business_id, occurred_at.
-- Lo dejo fuera de este sprint para no expandir scope.
--
-- BACKWARDS COMPAT
-- ────────────────
-- La firma del RPC se preserva (mismos parámetros), el cliente Flutter
-- (employee_repository.dart:updateUserPassword) sigue funcionando sin
-- cambios. Solo agrega rechazo en casos que ANTES estaban permitidos
-- por error.
--
-- Si la UI actual de gestión de usuarios permite a un cajero invocar
-- este RPC (lo cual sería un bug aparte), el RPC ahora lo rechazará
-- con un error claro — útil para detectar superficies que también
-- necesitan endurecimiento.
-- =============================================================================

begin;

create or replace function public.admin_update_user_password(
  target_user_id uuid,
  new_password text
)
returns void
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_caller_uid uuid := auth.uid();
  v_has_authority boolean;
begin
  -- ── Guard 1: caller autenticado ───────────────────────────────────────
  if v_caller_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if target_user_id is null then
    raise exception 'TARGET_USER_ID_REQUIRED';
  end if;

  -- ── Guard 2: bloquear self-update ─────────────────────────────────────
  -- Cambiar su propia password por este RPC saltaría el re-auth con la
  -- pass actual. El flujo correcto para self es auth.updateUser con
  -- signInWithPassword previo (ver MyAccountScreen).
  if v_caller_uid = target_user_id then
    raise exception 'SELF_PASSWORD_CHANGE_NOT_ALLOWED_VIA_ADMIN_RPC '
      'usa el flujo de Mi Cuenta';
  end if;

  -- ── Guards 3 + 4: authoritative para target en business compartido ───
  -- El caller debe tener rol owner/admin en AL MENOS UN business donde
  -- el target también es empleado. Esto evita cross-tenant attacks
  -- (cajero de negocio A no puede tocar password de empleado de B) y
  -- evita escalada de privilegios (cajero del mismo negocio que el
  -- dueño no puede reseteárselo).
  select exists (
    select 1
    from public.employees target_emp
    join public.employees caller_emp
      on caller_emp.business_id = target_emp.business_id
    where target_emp.user_id = target_user_id
      and caller_emp.user_id = v_caller_uid
      and public.user_business_role(v_caller_uid, target_emp.business_id)
            = any (array['owner'::text, 'admin'::text])
  )
  into v_has_authority;

  if not v_has_authority then
    raise exception 'NOT_AUTHORIZED_FOR_TARGET_USER';
  end if;

  -- ── Validación de password (preservada del fix legacy) ────────────────
  if new_password is null or length(new_password) < 6 then
    raise exception 'PASSWORD_TOO_SHORT';
  end if;

  -- ── Update real ───────────────────────────────────────────────────────
  update auth.users
  set
    encrypted_password = extensions.crypt(new_password, extensions.gen_salt('bf')),
    updated_at = now()
  where id = target_user_id;

  if not found then
    raise exception 'USER_NOT_FOUND';
  end if;
end;
$$;

comment on function public.admin_update_user_password(uuid, text) is
  'Permite a un owner/admin de un business resetear la password de '
  'OTRO empleado de ese mismo business. Bloquea self-update (debe usar '
  'flow re-auth en Mi Cuenta) y cross-tenant (no puedes tocar users '
  'de un business donde no tienes rol owner/admin).';

-- El grant se mantiene (authenticated) — los guards internos hacen
-- el filtrado fino por rol y pertenencia.
grant execute on function public.admin_update_user_password(uuid, text)
  to authenticated;

commit;
