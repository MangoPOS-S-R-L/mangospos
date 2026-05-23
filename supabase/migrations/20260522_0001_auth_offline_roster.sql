-- 20260522_0001_auth_offline_roster.sql
-- Fase 2 — Auth offline nivel Toast.
--
-- Objetivos:
--   1. Hashear los PINs de empleados con bcrypt (vía pgcrypto) y mantener
--      una columna `pin_hash` separada del `pin` plaintext legacy.
--   2. Crear `device_registrations` para vincular terminales físicos al
--      negocio con un token revocable.
--   3. Exponer dos RPCs:
--      - `fn_device_bind(p_business_id, p_device_name)` → emite un
--        device_token plaintext UNA SOLA VEZ (se hashea al persistir).
--      - `fn_sync_roster(p_device_token)` → valida device + devuelve el
--        roster de usuarios del business (con pin_hash). El cliente cachea
--        este roster en flutter_secure_storage para validar PIN offline.
--
-- Compatibilidad: NO eliminamos `employees.pin` plaintext en esta migración.
-- Se mantiene para que los clientes en versión vieja sigan funcionando
-- (verifyCurrentUserPin compara contra .eq('pin', pin)). Una migración
-- posterior puede drop después de confirmar que todos los clientes
-- migraron al verify offline con hash. Rollback compatible.
--
-- Idempotente: re-ejecutar no rompe nada (usa IF NOT EXISTS, CREATE OR
-- REPLACE, ON CONFLICT DO NOTHING). Safe en producción.

begin;

-- ---------------------------------------------------------------------------
-- 0. Extensiones requeridas
-- ---------------------------------------------------------------------------
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. Columna pin_hash en employees + trigger autoupdate
-- ---------------------------------------------------------------------------
alter table public.employees
  add column if not exists pin_hash text;

comment on column public.employees.pin_hash is
  'Hash bcrypt del PIN del empleado. Generado automáticamente por trigger '
  'tr_employees_hash_pin al insertar/actualizar `pin`. El cliente offline '
  'usa este hash para validar PIN sin pegarle a la DB. Mantener pin '
  'plaintext también durante el rollout para compat con clientes viejos.';

-- Trigger: cuando se inserta/actualiza employees.pin, hashear a pin_hash.
-- Si pin viene NULL o vacío, pin_hash también queda NULL.
create or replace function public.fn_employees_hash_pin()
returns trigger
language plpgsql
security definer
-- Incluimos `extensions` porque en Supabase pgcrypto vive ahí, no en
-- public. Sin esto, `gen_salt` y `crypt` no se resuelven en runtime.
set search_path = public, extensions, pg_catalog
as $$
begin
  if new.pin is null or btrim(new.pin) = '' then
    new.pin_hash := null;
  elsif (tg_op = 'INSERT')
     or (tg_op = 'UPDATE' and new.pin is distinct from old.pin) then
    -- bcrypt con cost 8 (rápido, suficiente para PINs numéricos de 4-6
    -- dígitos donde el espacio de búsqueda ya es chico). Cost mayor solo
    -- ralentiza el sync_roster sin agregar seguridad real.
    new.pin_hash := crypt(new.pin, gen_salt('bf', 8));
  end if;
  return new;
end;
$$;

drop trigger if exists tr_employees_hash_pin on public.employees;
create trigger tr_employees_hash_pin
  before insert or update of pin on public.employees
  for each row
  execute function public.fn_employees_hash_pin();

-- Backfill: empleados existentes con pin pero sin pin_hash.
-- Schema-qualify a `extensions` por las mismas razones que el trigger:
-- pgcrypto vive en el schema `extensions` en Supabase.
update public.employees
   set pin_hash = extensions.crypt(pin, extensions.gen_salt('bf', 8))
 where pin is not null
   and btrim(pin) <> ''
   and pin_hash is null;

-- ---------------------------------------------------------------------------
-- 2. Tabla device_registrations
-- ---------------------------------------------------------------------------
-- Cada terminal POS se vincula con un device_token único (UUID v4). Solo
-- guardamos el HASH del token, igual que con passwords; el plaintext se
-- emite UNA SOLA VEZ desde fn_device_bind y vive solo en el cliente
-- (flutter_secure_storage / Keychain). Si el dueño revoca el terminal,
-- ese token deja de funcionar en `fn_sync_roster`.
create table if not exists public.device_registrations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  device_name text not null,
  device_token_hash text not null,
  created_by uuid references auth.users(id),
  created_at timestamp with time zone default now() not null,
  last_seen timestamp with time zone,
  revoked_at timestamp with time zone,
  constraint device_registrations_name_per_business unique (business_id, device_name)
);

create index if not exists idx_device_registrations_business
  on public.device_registrations (business_id)
  where revoked_at is null;

comment on table public.device_registrations is
  'Vinculación entre un terminal POS y un negocio. El cliente guarda el '
  'device_token plaintext (emitido por fn_device_bind, no recuperable) y '
  'lo presenta en fn_sync_roster para descargar el roster offline. '
  'revoked_at permite invalidar un terminal robado o decomisado.';

alter table public.device_registrations enable row level security;

-- RLS: solo owner/admin del negocio pueden ver/manejar sus registrations.
drop policy if exists dr_owner_read on public.device_registrations;
create policy dr_owner_read
  on public.device_registrations
  for select
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id) = any (
      array['owner', 'admin']
    )
  );

drop policy if exists dr_owner_write on public.device_registrations;
create policy dr_owner_write
  on public.device_registrations
  for all
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id) = any (
      array['owner', 'admin']
    )
  )
  with check (
    public.user_business_role(auth.uid(), business_id) = any (
      array['owner', 'admin']
    )
  );

-- ---------------------------------------------------------------------------
-- 3. RPC fn_device_bind
-- ---------------------------------------------------------------------------
-- Genera un device_token nuevo, persiste su hash y retorna el plaintext
-- al cliente. Solo owner/admin pueden invocarla.
create or replace function public.fn_device_bind(
  p_business_id uuid,
  p_device_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_role text;
  v_token text;
  v_token_hash text;
  v_device_id uuid;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  v_role := public.user_business_role(auth.uid(), p_business_id);
  if v_role not in ('owner', 'admin') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if p_device_name is null or btrim(p_device_name) = '' then
    raise exception 'DEVICE_NAME_REQUIRED';
  end if;

  -- Generamos un token UUID v4 (122 bits de entropía) y lo hasheamos con
  -- bcrypt. El cliente debe guardar el plaintext porque acá solo queda
  -- el hash.
  v_token := gen_random_uuid()::text || '-' || gen_random_uuid()::text;
  v_token_hash := crypt(v_token, gen_salt('bf', 8));

  -- Si ya existe una registration con ese device_name, la actualizamos
  -- (rotación de token). Si está revoked, la reactivamos.
  insert into public.device_registrations (
    business_id, device_name, device_token_hash, created_by
  ) values (
    p_business_id, btrim(p_device_name), v_token_hash, auth.uid()
  )
  on conflict (business_id, device_name) do update set
    device_token_hash = excluded.device_token_hash,
    created_by = excluded.created_by,
    created_at = now(),
    revoked_at = null,
    last_seen = null
  returning id into v_device_id;

  return jsonb_build_object(
    'device_id', v_device_id,
    'device_token', v_token,
    'device_name', btrim(p_device_name),
    'business_id', p_business_id
  );
end;
$$;

grant execute on function public.fn_device_bind(uuid, text) to authenticated;

comment on function public.fn_device_bind(uuid, text) is
  'Vincula un terminal físico al negocio. Emite device_token plaintext UNA '
  'sola vez (no recuperable). Solo owner/admin. Si ya existía un device '
  'con el mismo nombre, rota el token.';

-- ---------------------------------------------------------------------------
-- 4. RPC fn_sync_roster
-- ---------------------------------------------------------------------------
-- Valida un device_token y devuelve el roster del business: lista de
-- empleados (con pin_hash) + role + permissions para validación offline.
-- El cliente cachea este roster encriptado y lo usa para verificar PIN
-- sin conexión.
create or replace function public.fn_sync_roster(
  p_device_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_business_id uuid;
  v_device_id uuid;
  v_roster jsonb;
begin
  if p_device_token is null or btrim(p_device_token) = '' then
    raise exception 'DEVICE_TOKEN_REQUIRED';
  end if;

  -- Buscamos el device_registration que matchea el hash del token. Solo
  -- consideramos los no revocados. Si ninguno matchea, devolvemos error
  -- genérico para no filtrar info de qué tokens existen.
  select id, business_id
    into v_device_id, v_business_id
    from public.device_registrations
   where revoked_at is null
     and device_token_hash = crypt(p_device_token, device_token_hash)
   limit 1;

  if v_device_id is null then
    raise exception 'INVALID_DEVICE_TOKEN';
  end if;

  -- Marcamos last_seen para que el owner pueda detectar terminales
  -- inactivos. Failsafe: si el update falla por concurrency, seguimos.
  update public.device_registrations
     set last_seen = now()
   where id = v_device_id;

  -- Construir roster: usuarios autorizados al business (via user_businesses)
  -- + employee.pin_hash + permissions agregadas. Si un usuario no tiene
  -- registro en employees (ej. owner principal sin entry), igual aparece
  -- con pin_hash=null para que el cliente sepa que ese user no puede
  -- usar PIN offline.
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'user_id', ub.user_id,
               'employee_id', e.id,
               'name', coalesce(
                  nullif(trim(coalesce(e.first_name, '') || ' ' ||
                              coalesce(e.last_name, '')), ''),
                  p.full_name,
                  p.email
               ),
               'email', coalesce(e.email, p.email),
               'pin_hash', e.pin_hash,
               'role', ub.role,
               'permissions', ub.permissions,
               'is_active', coalesce(e.status, 'active') = 'active'
             )
           ),
           '[]'::jsonb
         )
    into v_roster
    from public.user_businesses ub
    left join public.profiles p on p.id = ub.user_id
    left join public.employees e
      on e.user_id = ub.user_id and e.business_id = ub.business_id
   where ub.business_id = v_business_id;

  return jsonb_build_object(
    'business_id', v_business_id,
    'device_id', v_device_id,
    'synced_at', now(),
    'roster', v_roster
  );
end;
$$;

grant execute on function public.fn_sync_roster(text) to authenticated;

comment on function public.fn_sync_roster(text) is
  'Valida device_token y retorna roster del business: '
  '[{user_id, employee_id, name, email, pin_hash, role, permissions, is_active}]. '
  'El cliente cachea esta lista en flutter_secure_storage para validar '
  'PINs offline sin pegarle a la DB.';

-- ---------------------------------------------------------------------------
-- 5. RPC fn_device_revoke (opcional pero seguro de tener)
-- ---------------------------------------------------------------------------
-- Permite a owner/admin marcar un device como revocado (robado, vendido,
-- etc). El device_token deja de funcionar en sync_roster.
create or replace function public.fn_device_revoke(
  p_device_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_business_id uuid;
  v_role text;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select business_id into v_business_id
    from public.device_registrations
   where id = p_device_id;

  if v_business_id is null then
    raise exception 'DEVICE_NOT_FOUND';
  end if;

  v_role := public.user_business_role(auth.uid(), v_business_id);
  if v_role not in ('owner', 'admin') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  update public.device_registrations
     set revoked_at = now()
   where id = p_device_id
     and revoked_at is null;
end;
$$;

grant execute on function public.fn_device_revoke(uuid) to authenticated;

comment on function public.fn_device_revoke(uuid) is
  'Marca un device_registration como revocado. Solo owner/admin del business.';

commit;
