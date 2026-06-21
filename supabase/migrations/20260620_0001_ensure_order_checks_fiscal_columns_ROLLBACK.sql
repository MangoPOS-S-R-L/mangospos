-- =============================================================================
-- ROLLBACK de 20260620_0001_ensure_order_checks_fiscal_columns.sql
--
-- NO-OP intencional. Esta migración solo GARANTIZA la existencia de columnas
-- (`add column if not exists`) que son compartidas con 20260511_0003 y
-- contienen datos fiscales por sub-cuenta (customer_id, customer_rnc,
-- requested_ncf_type). Eliminarlas rompería fn_process_payment_v3 y perdería
-- la asignación de cliente/comprobante por check. Si de verdad necesitas
-- quitarlas, hazlo revirtiendo 20260511_0003 (su dueña lógica), no esta.
-- =============================================================================

-- (sin cambios)
select 1;
