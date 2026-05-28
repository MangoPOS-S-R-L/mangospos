-- Rollback de 20260527_0006_dashboard_kpis.sql
DROP FUNCTION IF EXISTS public.fn_dashboard_kpis(
  uuid, timestamptz, timestamptz, timestamptz, timestamptz
);
