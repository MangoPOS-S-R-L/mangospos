-- ============================================================================
-- Reemitir la E31 de Tropella con un e-NCF NUEVO
-- ============================================================================
-- POR QUE: E310000000001 quedo FIRMADO y rechazado por la DGII (176). Alanube
-- ya no acepta otro POST con ese numero (AP3001 "ENCF document was used"), y
-- su API no tiene forma de liberarlo. La salida es emitir la misma venta con
-- el siguiente numero de la secuencia.
--
-- QUE NO SE HACE Y POR QUE:
--   NO se le cambia el numero a la fila vieja. La DGII tiene E310000000001
--   registrado como rechazado; borrarlo de nuestros libros dejaria un numero
--   del que no podriamos dar cuenta si lo preguntan. Se queda, marcado.
--
-- La fila vieja pasa a `cancelled` a proposito: con dos documentos activos
-- para la misma venta, los reportes (y el 607) contarian la venta dos veces.
-- ============================================================================

begin;

-- 1) El comprobante quemado queda fuera de circulacion, pero registrado.
update public.fiscal_documents
   set status              = 'cancelled',
       cancelled_at        = coalesce(cancelled_at, now()),
       cancellation_reason = 'e-NCF rechazado por la DGII (176) y consumido en '
                             'Alanube (AP3001). Reemplazado por un e-NCF nuevo.'
 where id = 'd2aec7d4-7cdc-4320-9646-6b2b1761bfa8'::uuid
returning ncf_number, status, ecf_status;

-- 2) Mismo pedido, mismo pago, mismos montos, numero nuevo.
--    El trigger tg_alanube_enqueue_emission encola la emision solo.
--    OJO: no se copia idempotency_key — con la misma clave Alanube
--    devolveria la respuesta del documento viejo.
with viejo as (
  select * from public.fiscal_documents
  where id = 'd2aec7d4-7cdc-4320-9646-6b2b1761bfa8'::uuid
)
insert into public.fiscal_documents (
  business_id, order_id, check_id, payment_id, customer_id,
  ncf_type, ncf_number, ncf_sequence_id,
  customer_rnc, customer_name, customer_address,
  subtotal, discount, tax_exempt, taxable_amount, itbis_amount,
  service_fee, tip, total, is_electronic, issued_at, related_document_id
)
select v.business_id, v.order_id, v.check_id, v.payment_id, v.customer_id,
       v.ncf_type,
       public.generate_ncf(v.business_id, v.ncf_type),
       v.ncf_sequence_id,
       v.customer_rnc, v.customer_name, v.customer_address,
       v.subtotal, v.discount, v.tax_exempt, v.taxable_amount, v.itbis_amount,
       v.service_fee, v.tip, v.total, v.is_electronic,
       -- La fecha de emision es la de la VENTA, no la de hoy: la factura se
       -- cobro el 2 de septiembre y esa es la fecha fiscal del hecho.
       v.issued_at,
       v.id
from viejo v
returning id as nuevo_id, ncf_number, ecf_status;

-- 3) El pago apunta al comprobante nuevo (de ahi salen historial y reimpresion).
update public.payments p
   set fiscal_document_id = (
     select f.id from public.fiscal_documents f
     where f.related_document_id = 'd2aec7d4-7cdc-4320-9646-6b2b1761bfa8'::uuid
       and f.status = 'active'
     order by f.created_at desc limit 1
   )
 where p.fiscal_document_id = 'd2aec7d4-7cdc-4320-9646-6b2b1761bfa8'::uuid
returning p.id, p.fiscal_document_id;

commit;

-- Despues: pasame el `nuevo_id` del paso 2 y disparo la emision.
-- El cron tambien lo toma solo en <= 60s.
