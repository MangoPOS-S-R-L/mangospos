-- =============================================================================
-- Migration 1/3 del refactor de fiscal documents (2026-05-13).
--
-- OBJETIVO: snapshot del estado actual de las 4 tablas críticas antes de
-- modificar el flujo de emisión de NCF. Cero cambio lógico. Permite
-- rollback rápido si algo sale mal en migration 2.
--
-- CONTEXTO:
--   Hoy `trg_issue_fiscal` AFTER INSERT en payments llama a
--   `create_fiscal_document` que tiene idempotencia rota: matchea por
--   `order_id + status='active'`, así que en split por métodos (varios
--   payments de la misma orden) solo el primer payment emite NCF.
--   Los siguientes payments quedan con fiscal_document_id=NULL y el
--   historial muestra solo el primer monto (caso reportado: 500 pagado,
--   100 en historial).
--
--   Migration 2 reemplaza el trigger por dos nuevos disparados al cierre
--   de check (sub-cuenta) o de orden (full-order). Cada cierre emite UN
--   fd con la suma de payments del scope.
--
-- ROLLBACK: drop *_backup_20260513 cuando se confirme estabilidad tras
-- 7-14 días. Mientras tanto, si Migration 2 falla, restaurar desde estas
-- copias.
-- =============================================================================

begin;

-- Copia completa (estructura + datos) de las 4 tablas.
-- Usamos AS SELECT para no arrastrar constraints/triggers/FKs — son
-- snapshots de auditoría, no tablas operacionales.

create table public.payments_backup_20260513 as
select * from public.payments;

create table public.fiscal_documents_backup_20260513 as
select * from public.fiscal_documents;

create table public.order_checks_backup_20260513 as
select * from public.order_checks;

create table public.orders_backup_20260513 as
select * from public.orders;

-- Índices mínimos para que la query de audit/rollback no sea O(n).
create index idx_payments_bk_20260513_order on public.payments_backup_20260513(order_id);
create index idx_payments_bk_20260513_id on public.payments_backup_20260513(id);
create index idx_fd_bk_20260513_order on public.fiscal_documents_backup_20260513(order_id);
create index idx_fd_bk_20260513_id on public.fiscal_documents_backup_20260513(id);
create index idx_oc_bk_20260513_order on public.order_checks_backup_20260513(order_id);
create index idx_orders_bk_20260513_id on public.orders_backup_20260513(id);

-- Sanity: registra conteos para validar contra los reportados pre-migration.
do $$
declare
  v_pay int;
  v_fd int;
  v_oc int;
  v_o int;
begin
  select count(*) into v_pay from public.payments_backup_20260513;
  select count(*) into v_fd from public.fiscal_documents_backup_20260513;
  select count(*) into v_oc from public.order_checks_backup_20260513;
  select count(*) into v_o from public.orders_backup_20260513;
  raise notice 'Backup 20260513 listo: payments=%, fiscal_documents=%, order_checks=%, orders=%',
    v_pay, v_fd, v_oc, v_o;
end$$;

commit;
