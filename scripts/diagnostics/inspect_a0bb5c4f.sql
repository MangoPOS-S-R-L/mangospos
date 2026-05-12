-- ============================================================================
-- Inspección puntual: orden a0bb5c4f-8e57-4347-b088-4080a04e8e1e
--
-- Los dos payments con mismo método están separados por ~2 horas (23:43 →
-- 01:44 del día siguiente). Sospechamos pago partial legítimo en vez de
-- doble-tap. Confirmar antes del cleanup.
-- ============================================================================

-- 1) Estado de la orden + total
select
  o.id, o.status_ext, o.subtotal, o.discounts, o.service_fee, o.tax,
  o.total, o.closed_at, o.created_at
from public.orders o
where o.id = 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e';

-- 2) Items de la orden (suma de line totals)
select
  oi.id, oi.product_name, oi.quantity, oi.unit_price,
  oi.subtotal, oi.discounts, oi.tax, oi.total,
  oi.status, oi.created_at
from public.order_items oi
where oi.order_id = 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e'
order by oi.created_at asc;

-- 3) Todos los payments de esa orden (incluyendo cancelled / pending)
select
  p.id, p.amount, p.status, p.check_id, p.created_at,
  pm.code as method_code, pm.name as method_name,
  p.fiscal_document_id, p.reference
from public.payments p
left join public.payment_methods pm on pm.id = p.payment_method_id
where p.order_id = 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e'
order by p.created_at asc;

-- 4) Fiscal documents de esa orden
select
  fd.id, fd.ncf_number, fd.ncf_type, fd.total,
  fd.status as doc_status, fd.ecf_status, fd.payment_id,
  fd.created_at
from public.fiscal_documents fd
where fd.order_id = 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e'
order by fd.created_at asc;

-- 5) Cash transactions vinculadas (si el método era cash)
select
  ct.id, ct.amount, ct.type, ct.description, ct.created_at
from public.cash_transactions ct
where ct.related_order_id = 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e'
order by ct.created_at asc;

-- ============================================================================
-- Interpretación:
--   - Si order.total ≈ 1175 (625 + 550): fue partial legítimo. NO cancelar.
--   - Si order.total ≈ 625: el segundo fue duplicado, OK cancelar.
--   - Si hay 2 fiscal_documents distintos con NCFs activos: ambos pagos
--     fueron facturados → es partial real, no cancelar.
-- ============================================================================
