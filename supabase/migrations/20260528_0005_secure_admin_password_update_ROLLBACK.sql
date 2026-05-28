-- =============================================================================
-- ROLLBACK — 20260528_0005 — admin_update_user_password hardening
-- =============================================================================
--
-- Restaura la versión PREVIA (insegura) del fix 20260404_0001.
--
-- ⚠ ADVERTENCIA: aplicar este rollback REABRE el agujero crítico donde
-- cualquier usuario autenticado puede cambiarle la password a cualquier
-- otro user del sistema, incluido el dueño. Solo úsalo si el guard
-- nuevo introduce regresiones operativas que bloquean cambios legítimos
-- de password por parte de admins, mientras debuggeas el guard.
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
begin
  if new_password is null or length(new_password) < 6 then
    raise exception 'PASSWORD_TOO_SHORT';
  end if;

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

grant execute on function public.admin_update_user_password(uuid, text)
  to authenticated;

commit;
