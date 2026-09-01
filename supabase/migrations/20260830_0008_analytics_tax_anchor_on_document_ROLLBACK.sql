-- ROLLBACK de 20260830_0008_analytics_tax_anchor_on_document.sql
--
-- Vuelve a anclar el monto del impuesto en los items en vez de en el documento. Regresan:
--   * 292 documentos con items en void cuyo impuesto se cuela en el BRUTO
--   * 18 documentos con BRUTO NEGATIVO
--   * 49 descuadres en ordenes con subcuentas

begin;
drop view if exists analytics.documentos;
drop view if exists analytics.documentos_detalle;
commit;

-- Reaplicar la version anterior:
--     \i supabase/migrations/20260830_0007_analytics_fix_tax_split_and_voids.sql
