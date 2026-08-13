-- =============================================================================
-- ROLLBACK de 20260812_0001_fiscal_documents_update_policy.sql
--
-- Devuelve fiscal_documents al estado previo: sin policy de UPDATE para
-- `authenticated` y con el grant de UPDATE sobre todas las columnas (que era
-- inefectivo justamente por no haber policy).
--
-- OJO: al revertir, la anulación de ventas vuelve a dejar el NCF en 'active'
-- sin avisar.
-- =============================================================================

begin;

drop policy if exists fd_update on public.fiscal_documents;

-- Restaurar el grant amplio previo.
grant update on public.fiscal_documents to authenticated;

commit;
