-- Rollback de `20260521_0005_device_agents_extend.sql`.
--
-- IMPORTANTE: Esto restaura la firma vieja `fn_device_agent_heartbeat(uuid, text)`.
-- Si código nuevo (agent v2) ya está reportando agent_version/os/hostname/etc.,
-- esos campos quedan poblados pero la nueva versión del agent no podrá usar
-- la firma extendida — necesita rollback al binario anterior también.

begin;

-- 1. Restaurar la función vieja (firma `(uuid, text)`)
drop function if exists public.fn_device_agent_heartbeat(uuid, text, text, text, text, text[], jsonb);

create or replace function public.fn_device_agent_heartbeat(
  p_id uuid,
  p_agent_url text default null
) returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  update public.device_agents
  set online = true,
      last_heartbeat_at = now(),
      agent_url = coalesce(p_agent_url, agent_url),
      updated_at = now()
  where id = p_id;
end;
$$;

grant execute on function public.fn_device_agent_heartbeat(uuid, text)
  to anon, authenticated, service_role;

-- 2. Quitar el índice nuevo
drop index if exists public.idx_device_agents_business_hb_desc;

-- 3. Quitar columnas agregadas
alter table public.device_agents
  drop column if exists metadata,
  drop column if exists available_transports,
  drop column if exists hostname,
  drop column if exists os,
  drop column if exists agent_version;

commit;
