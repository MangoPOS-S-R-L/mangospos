-- Rollback de `20260521_0005_device_agents_health.sql`.

begin;

drop policy if exists "device_agents_health_delete" on public.device_agents_health;
drop policy if exists "device_agents_health_select" on public.device_agents_health;

drop function if exists public.fn_device_agent_heartbeat(text, uuid, text, text, text, text[], jsonb);

drop table if exists public.device_agents_health;

commit;
