-- ============================================================================
-- Limpieza pre-migración: duplicado en payments
-- order_id        : 6cadb1f4-c344-427b-a54c-bb5279ab5e97
-- payment_method  : 54e57ec8-ec53-4c1b-adeb-00ccc3b550a3 (probablemente cash)
-- check_id        : NULL
--
-- La migración 20260510_0003 falla al crear el nuevo unique index porque
-- existen ≥ 2 rows completed con esa key. Hay que decidir cuál es el
-- "bueno" y marcar el resto como cancelled antes de re-correr la migración.
--
-- USO:
--   1) Correr el bloque 1 (diagnóstico) para ver las filas duplicadas.
--   2) Elegir cuál payment es el válido (probablemente el más antiguo,
--      asociado al fiscal_document real).
--   3) Editar el bloque 2 (cleanup) reemplazando <PAYMENT_ID_A_CONSERVAR>
--      por el id elegido.
--   4) Correr el bloque 2 dentro de una transacción.
--   5) Re-aplicar 20260510_0003_split_full_order_payments.sql.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- BLOQUE 1: Diagnóstico
-- ----------------------------------------------------------------------------

-- 1.1) Las filas duplicadas
select
  p.id              as payment_id,
  p.amount,
  p.status,
  p.check_id,
  p.created_at,
  p.session_id      as cashier_session_id,
  pm.code           as method_code,
  pm.name           as method_name,
  p.reference,
  p.fiscal_document_id
from public.payments p
left join public.payment_methods pm on pm.id = p.payment_method_id
where p.order_id = '6cadb1f4-c344-427b-a54c-bb5279ab5e97'
  and p.check_id is null
  and p.payment_method_id = '54e57ec8-ec53-4c1b-adeb-00ccc3b550a3'
  and p.status = 'completed'
order by p.created_at asc;

-- 1.2) La orden afectada (para saber qué venta era)
select
  o.id, o.status_ext, o.subtotal, o.tax, o.total,
  o.closed_at, o.created_at, o.session_id
from public.orders o
where o.id = '6cadb1f4-c344-427b-a54c-bb5279ab5e97';

-- 1.3) Documentos fiscales asociados (para no romper la conexión con DGII)
select
  fd.id, fd.ncf_number, fd.ncf_type, fd.total,
  fd.status as doc_status, fd.ecf_status, fd.payment_id,
  fd.is_electronic, fd.created_at
from public.fiscal_documents fd
where fd.order_id = '6cadb1f4-c344-427b-a54c-bb5279ab5e97'
order by fd.created_at asc;

-- 1.4) ¿Hay OTROS órdenes con duplicados? Si sí, repetir cleanup para cada uno
--      antes de la migración.
select
  order_id,
  coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid)
    as check_key,
  payment_method_id,
  count(*) as dup_count,
  array_agg(id order by created_at asc) as payment_ids,
  array_agg(amount order by created_at asc) as amounts,
  array_agg(created_at order by created_at asc) as created_ats
from public.payments
where status = 'completed'
group by 1, 2, 3
having count(*) > 1
order by dup_count desc;


-- ----------------------------------------------------------------------------
-- BLOQUE 2: Cleanup (EDITAR antes de correr)
-- ----------------------------------------------------------------------------
-- Reemplazar:
--   <PAYMENT_ID_BUENO>  → el id de la fila que se queda como 'completed'
--                         (típicamente la más antigua, la que tiene
--                         fiscal_document_id no nulo).
--
-- Las demás filas pasan a status 'cancelled' (no se borran, queda audit
-- trail). Si el método era cash, también revertimos la entrada en
-- cash_transactions para que el cierre de caja no cuente duplicado.
-- ----------------------------------------------------------------------------

/*
begin;

-- 2.1) Marcar como cancelled todas las filas duplicadas excepto la elegida
update public.payments
set status = 'cancelled'
where order_id = '6cadb1f4-c344-427b-a54c-bb5279ab5e97'
  and check_id is null
  and payment_method_id = '54e57ec8-ec53-4c1b-adeb-00ccc3b550a3'
  and status = 'completed'
  and id <> '<PAYMENT_ID_BUENO>';

-- 2.2) Revertir cash_transactions de las que se cancelaron (sólo si method=cash).
--      Esto resta los duplicados del cash drawer para que el cierre de caja
--      cuadre.
delete from public.cash_transactions
where related_order_id = '6cadb1f4-c344-427b-a54c-bb5279ab5e97'
  and type = 'sale'
  and id in (
    -- Subquery vacía si la lógica ya está correcta; manualmente identificar
    -- las cash_transactions duplicadas mirando created_at vs los payments
    -- cancelled arriba.
    select id from public.cash_transactions
    where related_order_id = '6cadb1f4-c344-427b-a54c-bb5279ab5e97'
      and type = 'sale'
    order by created_at desc
    limit (
      select count(*) - 1
      from public.payments
      where order_id = '6cadb1f4-c344-427b-a54c-bb5279ab5e97'
        and status = 'completed'
        and payment_method_id = '54e57ec8-ec53-4c1b-adeb-00ccc3b550a3'
    )
  );

-- 2.3) Verificar: debe quedar 1 sola row completed para esa key
select count(*) as completed_remaining
from public.payments
where order_id = '6cadb1f4-c344-427b-a54c-bb5279ab5e97'
  and check_id is null
  and payment_method_id = '54e57ec8-ec53-4c1b-adeb-00ccc3b550a3'
  and status = 'completed';
-- Esperado: 1.

commit;
-- O rollback; si algo se ve mal.
*/
