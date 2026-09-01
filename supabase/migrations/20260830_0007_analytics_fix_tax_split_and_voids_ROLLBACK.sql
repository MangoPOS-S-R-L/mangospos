-- ROLLBACK de 20260830_0007_analytics_fix_tax_split_and_voids.sql
--
-- Devuelve los dos defectos que corrige:
--   * el impuesto de los items sin order_item_tax_lines vuelve a colarse dentro del BRUTO
--     (931 de 11.002 ventas en prod)
--   * las ventas anuladas sin cancelled_at vuelven a contarse como venta sin devolucion
--     (12 casos en prod)

begin;
drop view if exists analytics.documentos;
drop view if exists analytics.documentos_detalle;
commit;

-- Reaplicar la version anterior:
--     \i supabase/migrations/20260830_0006_analytics_taxes_from_config.sql
