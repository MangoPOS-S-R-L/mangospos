-- 2026-05-24 — Hardening de search_path para funciones pgcrypto.
--
-- Diagnóstico: pg_proc muestra que estas dos funciones tienen
--   search_path = public, pg_catalog
-- en producción, SIN `extensions`. Por eso `gen_salt`/`crypt` no
-- resuelven y CUALQUIER intento de:
--   (a) crear/editar empleado con PIN → trigger tr_employees_hash_pin
--       llama fn_employees_hash_pin → 42883
--   (b) bind device offline → fn_device_bind → 42883
-- truena con "function gen_salt(unknown, integer) does not exist".
--
-- Fix doble:
--   1. search_path = public, extensions, pg_catalog
--   2. Schema-qualify TODAS las llamadas a pgcrypto
--      (extensions.crypt, extensions.gen_salt). Doble seguridad para
--      que aunque el search_path se rompa de nuevo, las llamadas
--      sigan resolviendo.
--
-- Idempotente: re-aplicar no cambia comportamiento si ya está bien.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. fn_employees_hash_pin — trigger BEFORE INSERT/UPDATE OF pin sobre employees.
-- ═══════════════════════════════════════════════════════════════════════════════
create or replace function public.fn_employees_hash_pin()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
begin
  if new.pin is null or btrim(new.pin) = '' then
    new.pin_hash := null;
  elsif (tg_op = 'INSERT')
     or (tg_op = 'UPDATE' and new.pin is distinct from old.pin) then
    -- bcrypt cost 8 (suficiente para PINs numéricos 4-6 dígitos).
    new.pin_hash := extensions.crypt(new.pin, extensions.gen_salt('bf', 8));
  end if;
  return new;
end;
$$;

-- Re-conectar el trigger (idempotente).
drop trigger if exists tr_employees_hash_pin on public.employees;
create trigger tr_employees_hash_pin
  before insert or update of pin on public.employees
  for each row
  execute function public.fn_employees_hash_pin();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. fn_device_bind — RPC que emite device_token para login offline (Fase 2).
-- ═══════════════════════════════════════════════════════════════════════════════
-- Misma raíz: search_path sin extensions. Si se invoca para registrar un
-- tablet/POS al business, falla con 42883 y bloquea el flujo entero de
-- auth offline. Re-aplicado con la misma firma y semántica que la
-- versión canónica de 20260522_0001 pero con schema-qualify explícito.
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

  -- Token = dos UUID v4 concatenados (~244 bits de entropía).
  v_token := gen_random_uuid()::text || '-' || gen_random_uuid()::text;
  v_token_hash := extensions.crypt(v_token, extensions.gen_salt('bf', 8));

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

-- ═══════════════════════════════════════════════════════════════════════════════
-- Smoke check (manual)
-- ═══════════════════════════════════════════════════════════════════════════════
-- SELECT proname, proconfig
--   FROM pg_proc
--  WHERE proname IN ('fn_employees_hash_pin', 'fn_device_bind');
-- Ambas deben mostrar: {"search_path=public, extensions, pg_catalog"}
