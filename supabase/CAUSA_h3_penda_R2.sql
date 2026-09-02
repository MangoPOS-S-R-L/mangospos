-- =============================================================================
-- CAUSA de H-3 · ronda 2 — La Penda Express
--
-- LA HIPOTESIS DE LA CONSOLIDACION SE CAYO: los items existentes son ANTERIORES
-- al comprobante en los 4 casos. No fueron recreados.
--
-- LO QUE MOSTRARON LOS DATOS: H-3 no es un problema, son tres.
--   B0200159130  el subtotal CUADRA (1.502,12) pero se cobro 1.502,12 x 1,28.
--                Los items dicen 18%. Le quitaron la Ley DESPUES de cobrar.
--   B0200157123  faltan 55,00 exactos = el precio de un JUGO RICA DE PERA.
--   B0200159100  faltan 1.092,37 de items.
--   B0200158089  cero items y la orden quedo en 'sent_to_kitchen', ni llego a paid.
--
-- Y aparte: 24 comprobantes de agosto con items agregados DESPUES de facturar.
--
-- SOLO LECTURA.
-- =============================================================================

-- A ─── ¿Le quitaron impuestos a esas ordenes? ────────────────────────────────
--     Es la prueba de B0200159130. order_excluded_taxes guarda que impuesto se
--     saco de que orden; fn_set_order_excluded_taxes reescribe oi.tax_rate y
--     oi.tax de TODOS los items. Si se corre despues de cobrar, el pago queda
--     con la tasa vieja y los items con la nueva.
select d.ncf_number, t.name as impuesto_quitado, t.rate,
       oet.order_id, oet.*
from public.fiscal_documents d
join public.order_excluded_taxes oet on oet.order_id = d.order_id
join public.taxes t on t.id = oet.tax_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number in ('B0200159100','B0200159130','B0200157123','B0200158089');


-- B ─── ALCANCE de "quitar impuestos": ¿a cuantas ordenes de agosto? ──────────
--     Si son pocas, es un caso aislado. Si son muchas, cada una es un
--     comprobante potencialmente descuadrado.
select t.name as impuesto_quitado, t.rate,
       count(distinct oet.order_id)  as ordenes,
       count(distinct d.id)          as comprobantes,
       round(sum(distinct d.total), 2) as monto
from public.order_excluded_taxes oet
join public.taxes t on t.id = oet.tax_id
join public.fiscal_documents d on d.order_id = oet.order_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.status = 'active'
  and (d.issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31'
group by t.name, t.rate;


-- C ─── Los pagos de los 4, con el nombre real del metodo ─────────────────────
select d.ncf_number, p.amount, p.change_amount, pm.name as metodo, p.status,
       p.check_id, p.created_at,
       (p.fiscal_document_id = d.id) as apunta_a_este_ncf,
       round(p.amount / nullif(d.subtotal, 0), 4) as veces_el_subtotal
from public.fiscal_documents d
join public.payments p on p.order_id = d.order_id
left join public.payment_methods pm on pm.id = p.payment_method_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number in ('B0200159100','B0200159130','B0200157123','B0200158089')
order by d.ncf_number, p.created_at;


-- D ─── EL CUARTO FENOMENO: items agregados DESPUES de facturar ───────────────
--     24 comprobantes en agosto. Aqui el detalle: que se agrego, cuando, y
--     cuanto despues del NCF. Es el problema de ordenes que siguen vivas
--     despues de cobradas.
select d.ncf_number,
       d.issued_at,
       d.total                                              as facturado,
       oi.product_name, oi.quantity, oi.subtotal, oi.status,
       oi.created_at                                        as item_agregado,
       round(extract(epoch from (oi.created_at - d.issued_at))/60.0, 1)
                                                            as minutos_despues
from public.fiscal_documents d
join public.order_items oi on oi.order_id = d.order_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.status = 'active'
  and d.issued_at >= date '2026-08-01'
  and oi.created_at > d.issued_at + interval '1 second'
order by d.issued_at, oi.created_at;


-- E ─── ¿Existe candado contra agregar items a una orden ya facturada? ────────
--     La migracion 20260819_0004 (no_items_on_closed_order) fue escrita para
--     esto. Si el trigger no aparece, nunca se aplico.
select t.tgname, c.relname as tabla, p.proname as ejecuta,
       case t.tgenabled when 'O' then 'habilitado' else t.tgenabled::text end as estado
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_proc  p on p.oid = t.tgfoid
where c.relname = 'order_items' and not t.tgisinternal
order by t.tgname;
