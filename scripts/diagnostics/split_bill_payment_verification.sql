-- Verificación manual para escenarios de split bill y pagos mixtos
-- Reemplaza ORDER_ID cuando quieras auditar una orden concreta.

-- 1) Items por orden/check con qty real y quantity compat
select
  oi.order_id,
  oi.check_id,
  oc.label as check_label,
  oi.product_name,
  oi.qty,
  oi.quantity,
  oi.unit_price,
  oi.total,
  oi.status,
  oi.notes,
  oi.created_at
from public.order_items oi
left join public.order_checks oc on oc.id = oi.check_id
where oi.order_id = '<ORDER_ID>'
order by oc.position nulls first, oi.product_name, oi.created_at;

-- 2) Resumen por check
select
  oc.id,
  oc.label,
  oc.position,
  oc.is_closed,
  count(oi.id) as lines,
  sum(coalesce(oi.qty, oi.quantity::numeric, 0)) as qty_total,
  sum(oi.total) as total_items,
  oc.total as check_total
from public.order_checks oc
left join public.order_items oi on oi.check_id = oc.id and oi.status not in ('void','paid')
where oc.order_id = '<ORDER_ID>'
group by oc.id, oc.label, oc.position, oc.is_closed, oc.total
order by oc.position;

-- 3) Pagos por orden
select
  p.id,
  p.order_id,
  p.check_id,
  oc.label as check_label,
  p.amount,
  p.status,
  p.created_at
from public.payments p
left join public.order_checks oc on oc.id = p.check_id
where p.order_id = '<ORDER_ID>'
order by p.created_at desc;

-- 4) Estado final de checks
select
  id,
  order_id,
  label,
  position,
  is_closed,
  subtotal,
  tax,
  discounts,
  total,
  closed_at
from public.order_checks
where order_id = '<ORDER_ID>'
order by position;
