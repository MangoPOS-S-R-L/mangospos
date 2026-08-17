-- ═══════════════════════════════════════════════════════════════════════════════
-- 20260816_0002 — Hora de envío configurable por negocio
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- Hasta ahora la hora de corte del envío diario era una constante en la Edge
-- Function (RUN_AFTER_LOCAL_HOUR = 1), igual para todos. Cada local cierra a una
-- hora distinta, así que pasa a ser configurable desde la app.
--
-- Semántica: a las `send_hour_local` (hora LOCAL del negocio) se sube el archivo
-- del DÍA ANTERIOR. El cron sigue corriendo cada hora; la Edge Function ignora
-- las vueltas anteriores a esa hora y las de días ya subidos, así que el trabajo
-- real ocurre una vez al día.
--
-- Default 1 = 1:00 AM, que es el comportamiento que ya estaba en producción.
--
-- OJO en este stack: los objetos son de `supabase_admin`, no de `postgres`.
-- Aplicar con:  psql -U supabase_admin -d postgres -f <este archivo>
-- ═══════════════════════════════════════════════════════════════════════════════

begin;

alter table public.business_sales_export_config
  add column if not exists send_hour_local smallint not null default 1;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'business_sales_export_config_send_hour_local_check'
  ) then
    alter table public.business_sales_export_config
      add constraint business_sales_export_config_send_hour_local_check
      check (send_hour_local between 0 and 23);
  end if;
end $$;

comment on column public.business_sales_export_config.send_hour_local is
  'Hora local (0-23) a la que el cron sube el archivo del día anterior. '
  'Default 1 = 1:00 AM.';

commit;

-- Verificación:
--   select business_id, client_code, enabled, send_hour_local
--     from public.business_sales_export_config order by enabled desc;
