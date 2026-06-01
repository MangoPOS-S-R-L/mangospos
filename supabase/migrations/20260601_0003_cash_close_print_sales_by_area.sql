-- =============================================================================
-- 20260601_0003 — business_settings.cash_close_print_sales_by_area
-- =============================================================================
--
-- Toggle por negocio: si está true, el ticket de CIERRE DE CAJA incluye un
-- desglose de "Ventas por área de producción" (cocina, bar, caja…) con monto,
-- unidades y órdenes, para el periodo de la sesión que se cierra. La data
-- sale de la RPC get_sales_summary_v2 (campo sales_by_production_area), igual
-- que el reporte de Ventas → Por área de producción.
--
-- Default `false`: no cambia el ticket de ningún negocio existente sin opt-in.
--
-- Safe deploy: Flutter cae al default `false` si la columna aún no existe
-- (pre-migración) o si la query falla, así que el cierre sigue funcionando
-- normalmente antes y después de aplicar esta migración.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists cash_close_print_sales_by_area boolean
    not null default false;

comment on column public.business_settings.cash_close_print_sales_by_area is
  'Si true, el ticket de cierre de caja incluye un desglose de ventas por '
  'área de producción (cocina, bar, etc.) para el periodo de la sesión. '
  'Default false.';

commit;
