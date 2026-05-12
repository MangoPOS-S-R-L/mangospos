-- ============================================================================
-- Diagnóstico: por qué un split full-order generó 3 fiscal_documents?
-- ============================================================================
-- El user cobró 1 orden con split (cash 200, card 100, transfer 200) y vio
-- 3 facturas en el listado. Esperado: 1 factura por order.total = 500.
--
-- `issue_fiscal_document` (migration 20260426_0001) tiene dedup logic:
-- si existe un fd 'active' para el order, lo devuelve. Si esa lógica
-- está bien deployed, NO deberían crearse 3 fds. Algo no anda.
-- ============================================================================

-- 1) Encontrar el order más reciente (el test del user)
select
  o.id, o.status, o.status_ext, o.subtotal, o.tax, o.service_fee,
  o.total, o.closed_at, o.created_at
from public.orders o
order by o.created_at desc
limit 5;

-- 2) Para los últimos N orders, contar payments completed y fiscal_documents
select
  o.id              as order_id,
  o.total           as order_total,
  o.closed_at,
  (select count(*) from public.payments p
   where p.order_id = o.id and p.status = 'completed')      as payments_completed,
  (select count(*) from public.fiscal_documents fd
   where fd.order_id = o.id and fd.status = 'active')       as active_fds,
  (select count(*) from public.fiscal_documents fd
   where fd.order_id = o.id)                                as total_fds
from public.orders o
where o.created_at > now() - interval '24 hours'
order by o.created_at desc
limit 10;

-- 3) Reemplazar <ORDER_ID> abajo con el id del order de prueba (de query 1)
-- y correr para ver el detalle.
/*
select 'PAYMENTS' as section,
       p.id::text, p.amount::text, p.status, p.payment_method_id::text,
       pm.code as method, p.fiscal_document_id::text, p.created_at::text
from public.payments p
left join public.payment_methods pm on pm.id = p.payment_method_id
where p.order_id = '<ORDER_ID>'
order by p.created_at asc

union all

select 'FISCAL_DOCS',
       fd.id::text, fd.total::text, fd.status, fd.ncf_type::text,
       fd.ncf_number, fd.payment_id::text, fd.created_at::text
from public.fiscal_documents fd
where fd.order_id = '<ORDER_ID>'
order by 1, 7;
*/

-- 4) Verificar que el RPC v3 está deployed con el parámetro p_close_order
select
  proname,
  pronargs,
  pg_get_function_identity_arguments(oid) as signature
from pg_proc
where proname = 'fn_process_payment_v3';
-- Esperado: 1 row con signature que incluye `p_close_order boolean`.

-- 5) Verificar versión del issue_fiscal_document
select
  proname,
  pg_get_functiondef(oid) like '%fd.order_id = _order_id and fd.status = ''active''%'
    as has_dedup_logic
from pg_proc
where proname = 'issue_fiscal_document';
-- Esperado: has_dedup_logic = true.
