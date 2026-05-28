-- Rollback de 20260527_0004_dashboard_rpcs.sql
-- Borra los 2 RPCs nuevos del dashboard. El dashboard Fase A deja de
-- mostrar Top Selling Items y Recent Orders (cae a estado vacío).

DROP FUNCTION IF EXISTS public.fn_dashboard_top_selling_products(uuid, timestamptz, timestamptz, integer);
DROP FUNCTION IF EXISTS public.fn_dashboard_recent_orders(uuid, integer);
