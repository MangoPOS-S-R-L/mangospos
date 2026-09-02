-- =============================================================================
-- CAUSA de H-3 — La Penda Express
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- LOS 4 CASOS (todos con pagos COMPLETADOS y CERO items anulados, o sea que
-- NO es el bug de anulacion de H-4):
--   B0200159100  31-ago  total 1.377,97  con 1 item de 75,40
--   B0200159130  31-ago  total 1.922,71  con 4 items de 1.502,12
--   B0200157123  20-ago  total   371,20  con 2 items de 235,00
--   B0200158089  25-ago  total    88,50  con CERO items    <-- la clave
--
-- HIPOTESIS: los items no fueron anulados sino BORRADOS. Hay funciones de
-- consolidacion de splits fraccionados (fn_consolidate_order_to_integer,
-- fn_consolidate_keeper_atomic) que borran y recrean filas de order_items.
-- Si el comprobante se emitio ANTES de consolidar, queda apuntando a items
-- que ya no existen.
--
-- SOLO LECTURA.
-- =============================================================================

-- A ─── La orden completa de cada caso: ¿hay hermanos? ────────────────────────
--     Si la orden tiene VARIOS comprobantes, el total de cada uno se compara
--     contra los items de SU subcuenta, no contra los de toda la orden.
select
  d.ncf_number, d.issued_at, d.check_id, d.subtotal, d.total, d.status,
  (select count(*) from public.fiscal_documents f2
    where f2.order_id = d.order_id)                       as fds_de_la_orden,
  (select count(*) from public.order_checks c
    where c.order_id = d.order_id)                        as subcuentas,
  o.status_ext, o.subtotal as orden_subtotal, o.tax as orden_tax,
  o.total as orden_total, o.created_at as orden_creada, o.closed_at,
  d.order_id
from public.fiscal_documents d
join public.orders o on o.id = d.order_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number in ('B0200159100','B0200159130','B0200157123','B0200158089')
order by d.issued_at;


-- B ─── TODOS los comprobantes de esas ordenes ────────────────────────────────
--     Si hay hermanos, la "falta" de un documento puede ser el sobrante de otro.
select d2.ncf_number, d2.issued_at, d2.check_id, d2.subtotal, d2.total, d2.status
from public.fiscal_documents d2
where d2.order_id in (
  select order_id from public.fiscal_documents
  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and ncf_number in ('B0200159100','B0200159130','B0200157123','B0200158089')
)
order by d2.order_id, d2.issued_at;


-- C ─── TODOS los items de esas ordenes, con su hora ──────────────────────────
--     LA CLAVE: comparar `created_at` del item contra `issued_at` del NCF.
--     Si los items existentes son POSTERIORES a la emision, fueron RECREADOS
--     (consolidacion) y los originales se borraron.
select d.ncf_number, d.issued_at,
       oi.product_name, oi.quantity, oi.qty, oi.status, oi.check_id,
       oi.subtotal, oi.tax, oi.tax_rate, oi.created_at,
       (oi.created_at > d.issued_at) as item_creado_DESPUES_del_ncf
from public.fiscal_documents d
left join public.order_items oi on oi.order_id = d.order_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number in ('B0200159100','B0200159130','B0200157123','B0200158089')
order by d.ncf_number, oi.created_at;


-- D ─── Los pagos: cuanto se cobro y cuando ───────────────────────────────────
select d.ncf_number, p.amount, p.change_amount, p.method, p.status,
       p.check_id, p.created_at,
       (p.fiscal_document_id = d.id) as apunta_a_este_ncf
from public.fiscal_documents d
join public.payments p on p.order_id = d.order_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number in ('B0200159100','B0200159130','B0200157123','B0200158089')
order by d.ncf_number, p.created_at;


-- E ─── ALCANCE: cuantas ordenes tienen items creados DESPUES de su NCF ───────
--     Es la huella de la consolidacion post-facturacion. Si son muchas,
--     H-3 no son 4 casos sino un patron.
select (d.issued_at at time zone 'America/Santo_Domingo')::date as fecha,
       count(distinct d.id)                                     as comprobantes,
       round(sum(distinct d.total), 2)                          as monto
from public.fiscal_documents d
join public.order_items oi on oi.order_id = d.order_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.status = 'active'
  and d.issued_at >= date '2026-08-01'
  and oi.created_at > d.issued_at + interval '1 second'
group by 1
order by 1;
