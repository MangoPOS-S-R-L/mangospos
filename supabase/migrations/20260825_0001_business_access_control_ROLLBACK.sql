-- ============================================================================
-- ROLLBACK de 20260825_0001_business_access_control.sql
--
-- Deja el sistema exactamente como estaba: sin bloqueo por falta de pago.
-- OJO: borra los controles manuales del operador (cortes programados,
-- prórrogas, mensajes). Si solo quieres apagar el bloqueo sin perder esa
-- configuración, NO corras esto — usa el kill switch:
--
--   update public.platform_access_policy set enforcement_enabled = false;
--   update public.business_access_control set enforcement = 'off';
-- ============================================================================

drop function if exists public.get_my_business_access(uuid);
drop function if exists public.fn_business_access_state(uuid);

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime drop table public.business_access_control;
    exception when others then
      null;
    end;
  end if;
end;
$$;

drop policy if exists "business_access_control operators all" on public.business_access_control;
drop policy if exists "platform_access_policy operators all" on public.platform_access_policy;

drop table if exists public.business_access_control;
drop table if exists public.platform_access_policy;
