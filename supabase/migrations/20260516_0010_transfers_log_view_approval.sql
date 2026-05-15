-- =============================================================================
-- Extender vista `v_inventory_transfers_log` para incluir campos de aprobación.
--
-- CONCEPTO:
--   La migration 20260516_0009 agregó `approved_at` y `approved_by` a
--   `stock_transfers` pero la vista de log no los exponía. Esta migration
--   actualiza la vista para que el frontend reciba esos campos al listar.
--
-- IDEMPOTENTE: CREATE OR REPLACE VIEW.
-- =============================================================================

begin;

drop view if exists public.v_inventory_transfers_log;

create or replace view public.v_inventory_transfers_log as
select
  st.id                  as transfer_id,
  st.business_id,
  st.from_business_id,
  bf.business_name       as from_business_name,
  st.to_business_id,
  bt.business_name       as to_business_name,
  (st.from_business_id <> st.to_business_id) as is_cross_business,
  st.transfer_number,
  st.status,
  st.from_warehouse_id,
  wf.name                as from_warehouse_name,
  st.to_warehouse_id,
  wt.name                as to_warehouse_name,
  st.sent_at,
  st.received_at,
  st.cancelled_at,
  st.approved_at,
  st.notes,
  st.created_by,
  pc.full_name           as created_by_name,
  st.received_by,
  pr.full_name           as received_by_name,
  st.approved_by,
  pa.full_name           as approved_by_name,
  (select count(*) from public.stock_transfer_items sti where sti.stock_transfer_id = st.id)
                         as item_count,
  (select coalesce(sum(sti.quantity_sent), 0)
     from public.stock_transfer_items sti where sti.stock_transfer_id = st.id)
                         as total_sent,
  (select coalesce(sum(coalesce(sti.quantity_received, 0)), 0)
     from public.stock_transfer_items sti where sti.stock_transfer_id = st.id)
                         as total_received
from public.stock_transfers st
left join public.warehouses wf on wf.id = st.from_warehouse_id
left join public.warehouses wt on wt.id = st.to_warehouse_id
left join public.businesses bf on bf.id = st.from_business_id
left join public.businesses bt on bt.id = st.to_business_id
left join public.profiles   pc on pc.id = st.created_by
left join public.profiles   pr on pr.id = st.received_by
left join public.profiles   pa on pa.id = st.approved_by;

comment on view public.v_inventory_transfers_log is
  'Log de transferencias entre bodegas con contexto cross-business + '
  'campos de aprobación (approved_at, approved_by_name).';

commit;
