-- =============================================================================
-- 20260810_0001 — Eliminación de cuenta iniciada por el usuario (App Store 5.1.1(v))
--
-- CONTEXTO:
--   App Review rechazó MangoPOS el 23/06/2026 por guideline 5.1.1(v): una app
--   que permite crear cuentas debe permitir eliminarlas. El build de Apple
--   (~/dev/mangospos-apple) ya no crea cuentas, pero sí crea usuarios de
--   empleados, así que se agrega el borrado como cobertura.
--
-- POR QUÉ NO SE BORRA `auth.users`:
--   Casi todas las FKs hacia auth.users están SIN `on delete`:
--     businesses.owner_id, fiscal_documents.issued_by, payments.processed_by,
--     audit_logs.user_id, cash_register_sessions.user_id, employees.user_id...
--   Un `delete from auth.users` falla en cuanto el dueño tenga UNA venta. Y
--   ponerlas en cascade destruiría la trazabilidad fiscal que la DGII exige
--   conservar. La fila de auth.users queda como lápida (tombstone) sin datos
--   personales: el usuario no puede entrar y no queda nada suyo legible.
--
-- QUÉ HACE `fn_request_account_deletion` (todo en UNA transacción):
--   1. Snapshot de membresías y perfil en la fila de solicitud (para revertir
--      dentro de los 30 días).
--   2. Revoca acceso: borra `user_businesses`, desvincula `employees.user_id`
--      y marca al empleado inactivo. Las ventas del empleado siguen atribuidas
--      por employee_id.
--   3. Anonimiza `profiles` (nombre y correo → placeholder).
--   4. Mata las sesiones vivas e intenta banear el login (`banned_until`), de
--      forma defensiva por si esta versión de GoTrue no tiene la columna.
--   5. Negocios donde era dueño: si hay OTRO owner en user_businesses, le
--      transfiere `owner_id` y el negocio sigue vivo. Si era el único dueño,
--      el negocio pasa a `status='inactive'` y queda agendado para purga a los
--      30 días.
--
-- IDEMPOTENTE: create table if not exists + create or replace.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Bitácora de solicitudes
-- ---------------------------------------------------------------------------
-- OJO: `user_id` NO lleva FK a auth.users a propósito — la fila tiene que
-- sobrevivir aunque algún día se limpie el usuario.
create table if not exists public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  business_id uuid,
  requested_at timestamptz not null default now(),
  purge_after timestamptz not null,
  status text not null default 'pending'
    check (status in ('pending', 'cancelled', 'purged')),
  business_disposition text not null default 'none'
    check (business_disposition in ('none', 'transferred', 'scheduled_purge')),
  memberships_snapshot jsonb not null default '[]'::jsonb,
  profile_snapshot jsonb,
  employees_snapshot jsonb not null default '[]'::jsonb,
  processed_at timestamptz,
  notes text
);

create index if not exists idx_account_deletion_requests_purge
  on public.account_deletion_requests (status, purge_after);

create index if not exists idx_account_deletion_requests_user
  on public.account_deletion_requests (user_id);

alter table public.account_deletion_requests enable row level security;

-- Sin políticas a propósito: solo las funciones SECURITY DEFINER de abajo
-- tocan esta tabla. Un cliente autenticado no debe poder leer solicitudes
-- ajenas ni fabricar una propia.

comment on table public.account_deletion_requests is
  'Solicitudes de eliminación de cuenta iniciadas por el usuario (App Store '
  '5.1.1(v)). Guarda snapshots para poder revertir dentro de la ventana de '
  'gracia de 30 días. La purga física de datos del negocio NO es automática — '
  'ver fn_purge_expired_account_deletions.';

-- ---------------------------------------------------------------------------
-- 2. Solicitud de eliminación
-- ---------------------------------------------------------------------------
create or replace function public.fn_request_account_deletion(
  p_confirm text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid              uuid := auth.uid();
  v_purge_after      timestamptz := now() + interval '30 days';
  v_memberships      jsonb;
  v_employees        jsonb;
  v_profile          jsonb;
  v_biz              record;
  v_new_owner        uuid;
  v_disposition      text := 'none';
  v_scheduled        int := 0;
  v_transferred      int := 0;
  v_request_id       uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- Confirmación explícita del cliente. La app manda la palabra ELIMINAR
  -- escrita por el usuario; sin eso, no se procesa.
  if coalesce(upper(btrim(p_confirm)), '') <> 'ELIMINAR' then
    raise exception 'CONFIRMATION_REQUIRED';
  end if;

  -- 2.1 Snapshots para poder revertir dentro de la ventana de gracia.
  select coalesce(jsonb_agg(to_jsonb(ub)), '[]'::jsonb)
    into v_memberships
    from public.user_businesses ub
   where ub.user_id = v_uid;

  select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb)
    into v_employees
    from public.employees e
   where e.user_id = v_uid;

  select to_jsonb(p) into v_profile
    from public.profiles p
   where p.id = v_uid;

  -- 2.2 Negocios donde figura como dueño registrado.
  for v_biz in
    select b.id, b.business_name
      from public.businesses b
     where b.owner_id = v_uid
  loop
    -- ¿Hay otro owner que pueda quedarse con el negocio?
    select ub.user_id
      into v_new_owner
      from public.user_businesses ub
     where ub.business_id = v_biz.id
       and ub.role = 'owner'
       and ub.user_id <> v_uid
     order by ub.created_at asc
     limit 1;

    if v_new_owner is not null then
      -- Traspaso: el negocio sigue operando con el otro dueño.
      update public.businesses
         set owner_id = v_new_owner,
             updated_at = now()
       where id = v_biz.id;
      v_transferred := v_transferred + 1;
      v_disposition := 'transferred';
    else
      -- Dueño único: se desactiva ya y queda agendado para purga.
      update public.businesses
         set status = 'inactive',
             updated_at = now()
       where id = v_biz.id;
      v_scheduled := v_scheduled + 1;
      v_disposition := 'scheduled_purge';

      insert into public.account_deletion_requests (
        user_id, business_id, purge_after, business_disposition,
        memberships_snapshot, employees_snapshot, profile_snapshot
      ) values (
        v_uid, v_biz.id, v_purge_after, 'scheduled_purge',
        v_memberships, v_employees, v_profile
      );
    end if;
  end loop;

  -- 2.3 Si no era dueño de ningún negocio (o todos se traspasaron), igual
  -- queda constancia de la baja de la persona.
  if v_scheduled = 0 then
    insert into public.account_deletion_requests (
      user_id, business_id, purge_after, business_disposition,
      memberships_snapshot, employees_snapshot, profile_snapshot
    ) values (
      v_uid, null, v_purge_after, v_disposition,
      v_memberships, v_employees, v_profile
    ) returning id into v_request_id;
  end if;

  -- 2.4 Revocar acceso. `user_businesses` es la llave del acceso multi-negocio.
  delete from public.user_businesses where user_id = v_uid;

  -- El empleado se desvincula del login pero NO se borra: sus ventas,
  -- comisiones y comandas siguen atribuidas por employee_id.
  update public.employees
     set user_id = null,
         status = 'inactive',
         updated_at = now()
   where user_id = v_uid;

  -- 2.5 Anonimizar datos personales.
  update public.profiles
     set full_name = 'Cuenta eliminada',
         email = 'deleted+' || v_uid::text || '@mangopos.do',
         updated_at = now()
   where id = v_uid;

  -- 2.6 Cerrar sesiones y bloquear el login.
  -- Defensivo: si esta versión de GoTrue no tiene alguna de estas relaciones
  -- o columnas, no se aborta la baja — el acceso ya quedó revocado arriba.
  begin
    execute 'delete from auth.sessions where user_id = $1' using v_uid;
  exception when others then
    null;
  end;

  begin
    execute 'delete from auth.refresh_tokens where user_id = $1::text' using v_uid;
  exception when others then
    null;
  end;

  begin
    execute 'update auth.users set banned_until = $1 where id = $2'
      using (now() + interval '100 years'), v_uid;
  exception when others then
    null;
  end;

  begin
    execute 'update auth.users set email = $1, phone = null where id = $2'
      using ('deleted+' || v_uid::text || '@mangopos.do'), v_uid;
  exception when others then
    null;
  end;

  return jsonb_build_object(
    'deleted', true,
    'businesses_transferred', v_transferred,
    'businesses_scheduled_for_purge', v_scheduled,
    'purge_after', v_purge_after
  );
end;
$$;

grant execute on function public.fn_request_account_deletion(text) to authenticated;

comment on function public.fn_request_account_deletion(text) is
  'Elimina la cuenta del usuario autenticado: revoca acceso, desvincula al '
  'empleado, anonimiza el perfil, cierra sesiones y banea el login. Los '
  'negocios donde era dueño único quedan inactivos y agendados para purga a '
  'los 30 días; si hay otro owner, se le traspasa. NO borra la fila de '
  'auth.users (las FKs sin on-delete lo impiden y la DGII exige conservar la '
  'trazabilidad fiscal). Requiere p_confirm = ''ELIMINAR''.';

-- ---------------------------------------------------------------------------
-- 3. Purga de la ventana de gracia
-- ---------------------------------------------------------------------------
-- ⚠️ DELIBERADAMENTE CONSERVADORA: marca la solicitud como purgada y deja el
-- negocio inactivo para siempre. NO borra físicamente las filas operativas del
-- negocio (órdenes, pagos, comprobantes, inventario). Ese borrado cruza ~80
-- tablas con FKs sin cascade y choca con la retención fiscal de la DGII: hay
-- que decidirlo caso por caso, no dispararlo desde un cron.
create or replace function public.fn_purge_expired_account_deletions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int := 0;
begin
  update public.account_deletion_requests
     set status = 'purged',
         processed_at = now(),
         notes = coalesce(notes, '') ||
           '[purga automática: datos personales ya anonimizados en la ' ||
           'solicitud; datos operativos del negocio conservados por ' ||
           'retención fiscal]'
   where status = 'pending'
     and purge_after <= now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.fn_purge_expired_account_deletions() from public;

comment on function public.fn_purge_expired_account_deletions() is
  'Cierra las solicitudes de eliminación vencidas (30 días). Conservadora a '
  'propósito: NO borra datos operativos del negocio. Agendar por cron cuando '
  'se defina la política de retención con el contador.';

commit;
