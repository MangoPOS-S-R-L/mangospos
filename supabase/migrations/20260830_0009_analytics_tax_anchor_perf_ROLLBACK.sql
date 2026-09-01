-- ROLLBACK de 20260830_0009_analytics_tax_anchor_perf.sql
-- Vuelve a la version con laterales, que dejaba /documentos en HTTP 500 por timeout.
-- Casi con seguridad NO es lo que quieres: si hay que retroceder, ir a 20260830_0007.
begin;
drop view if exists analytics.documentos;
drop view if exists analytics.documentos_detalle;
commit;
-- Para volver a la version anterior (lenta):
--     \i supabase/migrations/20260830_0008_analytics_tax_anchor_on_document.sql
-- Para volver a la ultima version RAPIDA y estable:
--     \i supabase/migrations/20260830_0007_analytics_fix_tax_split_and_voids.sql
