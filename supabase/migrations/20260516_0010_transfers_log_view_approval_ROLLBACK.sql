-- Rollback de `20260516_0010_transfers_log_view_approval.sql`.
-- Restaura la vista a la versión previa (sin campos de aprobación).

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
  st.notes,
  st.created_by,
  pc.full_name           as created_by_name,
  st.received_by,
  pr.full_name           as received_by_name,
  (select count(*) from public.stock_transfer_items sti where sti.stock_transfer_id = st.id) as item_count,
  (select coalesce(sum(sti.quantity_sent), 0) from public.stock_transfer_items sti where sti.stock_transfer_id = st.id) as total_sent,
  (select coalesce(sum(coalesce(sti.quantity_received, 0)), 0) from public.stock_transfer_items sti where sti.stock_transfer_id = st.id) as total_received
from public.stock_transfers st
left join public.warehouses wf on wf.id = st.from_warehouse_id
left join public.warehouses wt on wt.id = st.to_warehouse_id
left join public.businesses bf on bf.id = st.from_business_id
left join public.businesses bt on bt.id = st.to_business_id
left join public.profiles   pc on pc.id = st.created_by
left join public.profiles   pr on pr.id = st.received_by;

commit;
