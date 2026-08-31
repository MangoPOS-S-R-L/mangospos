-- ROLLBACK de 20260830_0006_analytics_taxes_from_config.sql
--
-- Devuelve el feed a 7 columnas con el ITBIS sacado de fiscal_documents.itbis_amount.
-- OJO lo que eso significa en LA PENDA EXPRESS: el feed vuelve a reportar ITBIS 0 en un
-- tercio de las facturas y a no mostrar la Ley 10% por ningun lado
-- (RD$ 1.386.226,43 sin representar en dos meses).
--
-- Se dropean las vistas primero porque 20260830_0001 usa CREATE OR REPLACE y la lista de
-- columnas cambio (entro ley_10 antes de total).

begin;
drop view if exists analytics.documentos;
drop view if exists analytics.documentos_detalle;
commit;

-- Y ahora reaplicar la version anterior, que recrea ambas con 7 columnas:
--     \i supabase/migrations/20260830_0001_analytics_perf.sql

-- El indice se deja: es aditivo y no molesta.
-- drop index if exists public.idx_order_item_tax_lines_item;
