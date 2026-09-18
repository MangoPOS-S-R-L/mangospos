-- =============================================================================
-- 20260918_0001 — Dispositivos con sesión iniciada + cierre de sesión remoto
-- =============================================================================
--
-- QUÉ AGREGA:
--   Ajustes → "Dispositivos conectados": el dueño/admin ve qué equipos tienen
--   una sesión abierta en el negocio (cuenta, empleado activo por PIN, versión,
--   última actividad) y puede cerrarle la sesión a uno a distancia o ponerle
--   un nombre ("Tablet barra") para distinguir equipos iguales.
--
-- POR QUÉ NO SE REUSA device_agents NI device_registrations:
--   - `device_agents` solo registra equipos que tienen el agente de impresión
--     corriendo (tablets y teléfonos nunca aparecen) y no sabe quién está
--     logueado.
--   - `device_registrations` es el vínculo del roster offline: opcional, lo
--     crea el dueño a mano y tampoco dice quién está logueado.
--
-- COSTO (ver [[project_storage_wal_egress_heartbeat]]):
--   El equipo llama `fn_device_session_ping` al iniciar sesión, al cambiar de
--   negocio o de empleado, al volver a la app y cada 5 min. ≈288 UPDATE/día
--   por equipo, contra ~11,500 del heartbeat de impresión. La tabla NO va en
--   la publicación de Realtime.
--
-- CIERRE REMOTO = COOPERATIVO:
--   `fn_device_session_revoke` solo marca `revoked_at`. El equipo se entera en
--   su próximo ping (≤5 min, o al volver a la app) y cierra su propia sesión.
--   No toca auth.sessions: la app ignora a propósito los fallos de refresh
--   para seguir operando offline, así que matar el refresh token dejaría al
--   equipo "logueado pero roto" en vez de sacarlo. Tampoco es un bloqueo: la
--   cuenta puede volver a entrar. Para impedirlo hay que cambiar la contraseña.
--
-- IDENTIDAD DE LA SESIÓN:
--   `session_key` es un aleatorio que el cliente genera al iniciar sesión y
--   borra al cerrarla. Una fila por (negocio, equipo): un login nuevo en el
--   mismo equipo trae otra key y "reinicia" la fila (limpia revoked_at).
--   Una misma key vive en UN negocio a la vez: al cambiar de sucursal la fila
--   del negocio anterior se cierra con end_reason = 'switched_business' y se
--   reabre si el equipo vuelve.
--
-- PERMISOS:
--   - ping: cualquier miembro del negocio (is_member_of_business o empleado
--     con login en ese negocio).
--   - listar / cerrar remoto / renombrar: is_admin_of_business (owner, admin, rol de
--     empleado nivel admin, dueño por owner_id, usuario compartido admin).
--   La tabla no tiene policies de escritura: solo se escribe por estos RPC.
--
-- Idempotente. Rollback: 20260918_0001_device_sessions_ROLLBACK.sql
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Tabla
-- ---------------------------------------------------------------------------
create table if not exists public.device_sessions (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  device_id     text not null,
  session_key   text not null,
  user_id       uuid references auth.users(id) on delete set null,
  user_email    text,
  user_name     text,
  employee_id   uuid references public.employees(id) on delete set null,
  employee_name text,
  label         text,
  device_name   text,
  hostname      text,
  platform      text,
  os_version    text,
  app_version   text,
  signed_in_at  timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  signed_out_at timestamptz,
  end_reason    text,
  revoked_at    timestamptz,
  revoked_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  constraint device_sessions_device_per_business unique (business_id, device_id),
  constraint device_sessions_end_reason_check check (
    end_reason is null
    or end_reason in ('signed_out', 'revoked', 'switched_business')
  )
);

-- Para cerrar las filas de otros negocios de la misma sesión (cambio de
-- sucursal). Parcial: solo las abiertas.
create index if not exists idx_device_sessions_open_device
  on public.device_sessions (device_id)
  where signed_out_at is null;

comment on table public.device_sessions is
  'Una fila por (negocio, equipo) con la sesión abierta en ese equipo. La '
  'escribe solo fn_device_session_ping (desde el propio equipo), '
  'fn_device_session_revoke (cierre remoto) y fn_device_session_rename '
  '(etiqueta del admin). Ver migración 20260918_0001.';
comment on column public.device_sessions.device_id is
  'ID de instalación del cliente (DeviceUtils.getDeviceId, SharedPreferences).';
comment on column public.device_sessions.session_key is
  'Aleatorio del cliente por inicio de sesión. Cambia en cada login; distingue '
  'un login nuevo de un ping tardío de una sesión ya cerrada.';
comment on column public.device_sessions.label is
  'Nombre que le pone el admin ("Tablet barra"). El ping NUNCA lo toca, así '
  'sobrevive a nuevos logins en el mismo equipo. device_name es el que '
  'reporta la app ("Android", "PC") y no distingue equipos iguales.';
comment on column public.device_sessions.revoked_at is
  'Cierre remoto pedido por un admin. El equipo lo ve en su próximo ping y '
  'cierra su propia sesión (cooperativo, no bloquea la cuenta).';

alter table public.device_sessions enable row level security;

drop policy if exists device_sessions_admin_read on public.device_sessions;
create policy device_sessions_admin_read
  on public.device_sessions
  for select
  to authenticated
  using (public.is_admin_of_business(business_id));

-- TRUNCATE incluido: el grant por defecto de Supabase lo da y RLS no lo frena.
revoke insert, update, delete, truncate on public.device_sessions from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. fn_device_session_ping — el equipo reporta su sesión
-- ---------------------------------------------------------------------------
-- Devuelve {session_id, revoked, closed}:
--   revoked = true → un admin pidió cerrar esta sesión: el cliente debe
--                    llamar de nuevo con p_signed_out = true y desloguearse.
--   closed  = true → esta key ya estaba cerrada (ping tardío). El cliente
--                    debe generar otra key y volver a reportar.
create or replace function public.fn_device_session_ping(
  p_business_id uuid,
  p_device_id   text,
  p_session_key text,
  p_device_name text    default null,
  p_hostname    text    default null,
  p_platform    text    default null,
  p_os_version  text    default null,
  p_app_version text    default null,
  p_employee_id uuid    default null,
  p_signed_out  boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_uid      uuid := auth.uid();
  v_row      public.device_sessions%rowtype;
  v_email    text;
  v_name     text;
  v_emp_id   uuid;
  v_emp_name text;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_business_id is null
     or coalesce(btrim(p_device_id), '') = ''
     or coalesce(btrim(p_session_key), '') = ''
     or length(p_device_id) > 128
     or length(p_session_key) > 128 then
    raise exception 'INVALID_ARGUMENTS';
  end if;

  if not (
    public.is_member_of_business(p_business_id)
    or exists (
      select 1 from public.employees e
       where e.business_id = p_business_id and e.user_id = v_uid
    )
  ) then
    raise exception 'ACCESS_DENIED';
  end if;

  -- ── Cierre de sesión explícito (logout normal o confirmación de revoke) ──
  if p_signed_out then
    update public.device_sessions s
       set signed_out_at = now(),
           last_seen_at  = now(),
           end_reason    = case when s.revoked_at is not null
                                then 'revoked' else 'signed_out' end
     where s.business_id = p_business_id
       and s.device_id   = p_device_id
       and s.session_key = p_session_key
       and s.signed_out_at is null
    returning * into v_row;

    return jsonb_build_object(
      'session_id', v_row.id,
      'revoked',    coalesce(v_row.revoked_at is not null, false),
      'closed',     true
    );
  end if;

  select p.email, nullif(btrim(p.full_name), '')
    into v_email, v_name
    from public.profiles p
   where p.id = v_uid;

  -- El nombre del empleado sale de la BD, no del cliente: solo se acepta un
  -- empleado de ESTE negocio.
  if p_employee_id is not null then
    select e.id,
           nullif(btrim(coalesce(e.first_name, '') || ' ' || coalesce(e.last_name, '')), '')
      into v_emp_id, v_emp_name
      from public.employees e
     where e.id = p_employee_id
       and e.business_id = p_business_id;
  end if;

  -- Una sesión vive en un negocio a la vez: al reportar aquí, la misma key
  -- en otras sucursales pasa a "cambió de negocio".
  update public.device_sessions s
     set signed_out_at = now(),
         end_reason    = 'switched_business'
   where s.device_id   = p_device_id
     and s.session_key = p_session_key
     and s.business_id <> p_business_id
     and s.signed_out_at is null;

  insert into public.device_sessions as s (
    business_id, device_id, session_key,
    user_id, user_email, user_name,
    employee_id, employee_name,
    device_name, hostname, platform, os_version, app_version
  ) values (
    p_business_id, p_device_id, p_session_key,
    v_uid, v_email, v_name,
    v_emp_id, v_emp_name,
    left(nullif(btrim(p_device_name), ''), 120),
    left(nullif(btrim(p_hostname), ''), 120),
    left(nullif(btrim(p_platform), ''), 40),
    left(nullif(btrim(p_os_version), ''), 160),
    left(nullif(btrim(p_app_version), ''), 40)
  )
  on conflict (business_id, device_id) do nothing
  returning * into v_row;

  if found then
    return jsonb_build_object('session_id', v_row.id, 'revoked', false, 'closed', false);
  end if;

  select * into v_row
    from public.device_sessions s
   where s.business_id = p_business_id
     and s.device_id   = p_device_id
   for update;

  if v_row.session_key = p_session_key then
    -- Ping tardío de una sesión que ya se cerró (logout o revoke): no se
    -- resucita. Solo se reabre si se cerró por cambio de sucursal.
    if v_row.signed_out_at is not null
       and v_row.end_reason is distinct from 'switched_business' then
      return jsonb_build_object(
        'session_id', v_row.id,
        'revoked',    v_row.end_reason = 'revoked',
        'closed',     true
      );
    end if;

    -- Revoke pendiente: se avisa al equipo y no se refresca nada más.
    if v_row.revoked_at is not null then
      update public.device_sessions s
         set last_seen_at = now()
       where s.id = v_row.id;
      return jsonb_build_object('session_id', v_row.id, 'revoked', true, 'closed', false);
    end if;

    update public.device_sessions s
       set user_id       = v_uid,
           user_email    = v_email,
           user_name     = v_name,
           employee_id   = v_emp_id,
           employee_name = v_emp_name,
           device_name   = coalesce(left(nullif(btrim(p_device_name), ''), 120), s.device_name),
           hostname      = coalesce(left(nullif(btrim(p_hostname), ''), 120), s.hostname),
           platform      = coalesce(left(nullif(btrim(p_platform), ''), 40), s.platform),
           os_version    = coalesce(left(nullif(btrim(p_os_version), ''), 160), s.os_version),
           app_version   = coalesce(left(nullif(btrim(p_app_version), ''), 40), s.app_version),
           last_seen_at  = now(),
           signed_out_at = null,
           end_reason    = null
     where s.id = v_row.id;

    return jsonb_build_object('session_id', v_row.id, 'revoked', false, 'closed', false);
  end if;

  -- Key distinta = login nuevo en este equipo: se reinicia la fila, incluido
  -- un revoke viejo (el cierre remoto no es un bloqueo de la cuenta).
  update public.device_sessions s
     set session_key   = p_session_key,
         user_id       = v_uid,
         user_email    = v_email,
         user_name     = v_name,
         employee_id   = v_emp_id,
         employee_name = v_emp_name,
         device_name   = coalesce(left(nullif(btrim(p_device_name), ''), 120), s.device_name),
         hostname      = coalesce(left(nullif(btrim(p_hostname), ''), 120), s.hostname),
         platform      = coalesce(left(nullif(btrim(p_platform), ''), 40), s.platform),
         os_version    = coalesce(left(nullif(btrim(p_os_version), ''), 160), s.os_version),
         app_version   = coalesce(left(nullif(btrim(p_app_version), ''), 40), s.app_version),
         signed_in_at  = now(),
         last_seen_at  = now(),
         signed_out_at = null,
         end_reason    = null,
         revoked_at    = null,
         revoked_by    = null
   where s.id = v_row.id;

  return jsonb_build_object('session_id', v_row.id, 'revoked', false, 'closed', false);
end;
$$;

revoke all on function public.fn_device_session_ping(
  uuid, text, text, text, text, text, text, text, uuid, boolean
) from public, anon;
grant execute on function public.fn_device_session_ping(
  uuid, text, text, text, text, text, text, text, uuid, boolean
) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. fn_device_sessions_list — lo que ve el admin
-- ---------------------------------------------------------------------------
-- Solo sesiones abiertas. idle_seconds se calcula en el servidor: los relojes
-- de los POS no son confiables ([[project_tls_cert_windows_clock]]).
-- Se ocultan: sesiones sin actividad en 90 días y revokes pendientes de más
-- de 7 días (equipo reinstalado o apagado para siempre).
create or replace function public.fn_device_sessions_list(p_business_id uuid)
returns table (
  id              uuid,
  device_id       text,
  label           text,
  device_name     text,
  hostname        text,
  platform        text,
  os_version      text,
  app_version     text,
  user_id         uuid,
  user_email      text,
  user_name       text,
  employee_id     uuid,
  employee_name   text,
  signed_in_at    timestamptz,
  last_seen_at    timestamptz,
  idle_seconds    integer,
  revoked_at      timestamptz,
  revoked_by_name text
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;
  if not public.is_admin_of_business(p_business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  return query
  select s.id,
         s.device_id,
         s.label,
         s.device_name,
         s.hostname,
         s.platform,
         s.os_version,
         s.app_version,
         s.user_id,
         s.user_email,
         s.user_name,
         s.employee_id,
         s.employee_name,
         s.signed_in_at,
         s.last_seen_at,
         greatest(0, extract(epoch from (now() - s.last_seen_at)))::integer,
         s.revoked_at,
         coalesce(nullif(btrim(rp.full_name), ''), rp.email)
    from public.device_sessions s
    left join public.profiles rp on rp.id = s.revoked_by
   where s.business_id = p_business_id
     and s.signed_out_at is null
     and s.last_seen_at > now() - interval '90 days'
     and (s.revoked_at is null or s.revoked_at > now() - interval '7 days')
   order by s.last_seen_at desc;
end;
$$;

revoke all on function public.fn_device_sessions_list(uuid) from public, anon;
grant execute on function public.fn_device_sessions_list(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. fn_device_session_revoke — cierre remoto
-- ---------------------------------------------------------------------------
create or replace function public.fn_device_session_revoke(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_row public.device_sessions%rowtype;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_row
    from public.device_sessions s
   where s.id = p_session_id
   for update;

  if not found then
    raise exception 'NOT_FOUND';
  end if;

  if not public.is_admin_of_business(v_row.business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  if v_row.signed_out_at is not null then
    return jsonb_build_object('session_id', v_row.id, 'already_closed', true);
  end if;

  update public.device_sessions s
     set revoked_at = coalesce(s.revoked_at, now()),
         revoked_by = coalesce(s.revoked_by, auth.uid())
   where s.id = v_row.id;

  return jsonb_build_object('session_id', v_row.id, 'already_closed', false);
end;
$$;

revoke all on function public.fn_device_session_revoke(uuid) from public, anon;
grant execute on function public.fn_device_session_revoke(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. fn_device_session_rename — etiqueta del admin ("Tablet barra")
-- ---------------------------------------------------------------------------
-- Vacío = quitar la etiqueta (vuelve a verse el nombre que reporta la app).
create or replace function public.fn_device_session_rename(
  p_session_id uuid,
  p_label      text
) returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_business_id uuid;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select s.business_id into v_business_id
    from public.device_sessions s
   where s.id = p_session_id;

  if not found then
    raise exception 'NOT_FOUND';
  end if;

  if not public.is_admin_of_business(v_business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  update public.device_sessions s
     set label = left(nullif(btrim(p_label), ''), 60)
   where s.id = p_session_id;
end;
$$;

revoke all on function public.fn_device_session_rename(uuid, text) from public, anon;
grant execute on function public.fn_device_session_rename(uuid, text) to authenticated;

commit;
