-- =============================================================================
-- ROLLBACK 20260616_0001 — Desglose de productos por área en el cierre
-- =============================================================================
-- Revierte la columna y la RPC del desglose por-producto por área. No afecta
-- datos: la columna es un flag y la RPC es de solo lectura.
-- =============================================================================

begin;

drop function if exists public.get_products_by_production_area(
  uuid, timestamp with time zone, timestamp with time zone
);

alter table public.business_settings
  drop column if exists cash_close_print_products_by_area;

commit;
