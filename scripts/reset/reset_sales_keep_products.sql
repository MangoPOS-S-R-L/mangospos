-- Reset de ventas/pagos/checks/fiscales relacionados
-- Conserva productos, catálogo y configuración.
-- Revísalo antes de ejecutar en producción.

-- =========================================================
-- PREVIEW: conteo de registros a eliminar
-- =========================================================
select 'dgii_logs' as table_name, count(*) from public.dgii_logs
union all
select 'fiscal_receipts', count(*) from public.fiscal_receipts
union all
select 'fiscal_documents', count(*) from public.fiscal_documents
union all
select 'payments', count(*) from public.payments
union all
select 'order_items', count(*) from public.order_items
union all
select 'order_checks', count(*) from public.order_checks
union all
select 'orders', count(*) from public.orders;

-- =========================================================
-- RESET
-- =========================================================
begin;

-- 1) Logs/artefactos fiscales ligados a ventas
delete from public.dgii_logs
where fiscal_receipt_id in (
  select id from public.fiscal_receipts
);

delete from public.fiscal_receipts;

delete from public.fiscal_documents;

-- 2) Pagos
delete from public.payments;

-- 3) Detalle operativo de ventas
delete from public.order_items;
delete from public.order_checks;

-- 4) Órdenes
delete from public.orders;

commit;

-- =========================================================
-- OPCIONAL: reiniciar secuencias identity/serial si aplica
-- Ejecuta esto solo si quieres volver a arrancar desde 1.
-- =========================================================
-- alter sequence if exists public.fiscal_receipts_id_seq restart with 1;
-- alter sequence if exists public.dgii_logs_id_seq restart with 1;
