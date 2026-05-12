-- ============================================================================
-- Diagnóstico: sale ORDEN D1DE2335 / e-NCF E320009708079
-- Reportado: cobrada con split (100 efectivo + 100 tarjeta + 300 transferencia
-- = 500) pero DB sólo registra 100. Confirmar qué quedó realmente en la base.
--
-- Correr en Supabase SQL Editor con role service_role (bypassa RLS).
-- ============================================================================

-- 1) ORDER row. Buscar por NCF para no depender del prefijo "D1DE2335".
--    Esperado: total = 500, status_ext = 'paid', closed_at no nulo.
select
  o.id            as order_id,
  o.session_id,
  o.status,
  o.status_ext,
  o.subtotal,
  o.discounts,
  o.service_fee,
  o.tax,
  o.total,
  o.closed_at,
  o.created_at
from public.orders o
join public.fiscal_documents fd on fd.order_id = o.id
where fd.ncf_number = 'E320009708079';

-- 2) Todos los payments asociados a ese order_id.
--    Esperado: 3 rows (efectivo 100, tarjeta 100, transferencia 300).
--    Probable: 1 row de 100 (efectivo) en status 'completed'.
select
  p.id            as payment_id,
  p.amount,
  p.status,
  p.check_id,
  p.payment_method_id,
  pm.code         as method_code,
  pm.name         as method_name,
  p.reference,
  p.session_id    as cashier_session_id,
  p.created_at
from public.payments p
left join public.payment_methods pm on pm.id = p.payment_method_id
where p.order_id = (
  select fd.order_id from public.fiscal_documents fd
  where fd.ncf_number = 'E320009708079' limit 1
)
order by p.created_at asc;

-- 3) Fiscal document — verificar monto registrado vs DGII.
--    El receipt mostró "Rechazado DGII: AP10077" así que probablemente
--    está en status 'pending' o 'rejected'.
select
  fd.id,
  fd.ncf_number,
  fd.ncf_type,
  fd.total,
  fd.status            as doc_status,
  fd.is_electronic,
  fd.ecf_status,
  fd.ecf_tracking_number,
  fd.ecf_security_code,
  fd.ecf_signed_at,
  fd.created_at
from public.fiscal_documents fd
where fd.ncf_number = 'E320009708079';

-- 4) Order items — para confirmar que el bruto sí está en 500.
select
  oi.id,
  mi.name as item_name,
  oi.quantity,
  oi.unit_price,
  oi.line_total,
  oi.tax_amount,
  oi.created_at
from public.order_items oi
left join public.menu_items mi on mi.id = oi.menu_item_id
where oi.order_id = (
  select fd.order_id from public.fiscal_documents fd
  where fd.ncf_number = 'E320009708079' limit 1
)
order by oi.created_at asc;

-- 5) Cualquier payment con status != 'completed' (intentos fallidos).
--    Útil para ver si los splits 2 y 3 quedaron como pending/cancelled.
select
  p.id, p.amount, p.status, p.created_at,
  pm.code as method_code, p.reference
from public.payments p
left join public.payment_methods pm on pm.id = p.payment_method_id
where p.order_id = (
  select fd.order_id from public.fiscal_documents fd
  where fd.ncf_number = 'E320009708079' limit 1
)
  and p.status <> 'completed'
order by p.created_at asc;

-- ============================================================================
-- Interpretación esperada de los resultados:
--   - Query 1: total = 500.00 (correcto).
--   - Query 2: una sola fila completed con amount = 100 method=cash (el bug).
--   - Query 3: total = 500 pero status 'rejected' o 'pending' (DGII falló por
--              mismatch o por otro AP10077; verificar last_error).
--   - Query 4: items sumando 500 (correcto).
--   - Query 5: vacío (los splits 2 y 3 nunca llegaron a insertar).
-- ============================================================================
