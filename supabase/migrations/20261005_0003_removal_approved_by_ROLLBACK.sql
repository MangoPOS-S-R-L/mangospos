-- =============================================================================
-- ROLLBACK de 20261005_0003 — Quién AUTORIZÓ con PIN el retiro de un producto
-- =============================================================================
--
-- OJO: borra las columnas y con ellas el registro de QUIÉN autorizó cada
-- retiro desde que se aplicó la migración. Si hace falta conservarlo, copiar
-- antes:
--
--   create table public.order_item_removals_approvals_bak as
--   select id, approved_by_employee_id, approved_by_user_id, approved_at
--     from public.order_item_removals
--    where approved_by_employee_id is not null;
--
-- La app tolera que la función no exista: el retiro y el comprobante siguen
-- funcionando, solo que sin el sello del aprobador.
-- =============================================================================

begin;

drop function if exists public.fn_approve_order_item_removal(uuid, text);

drop index if exists public.idx_order_item_removals_approved_by;

alter table public.order_item_removals
  drop column if exists approved_at,
  drop column if exists approved_by_user_id,
  drop column if exists approved_by_employee_id;

notify pgrst, 'reload schema';

commit;
