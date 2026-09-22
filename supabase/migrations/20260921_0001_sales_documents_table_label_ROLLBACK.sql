-- ROLLBACK de 20260921_0001 — la vista sales_documents vuelve a como la dejó
-- 20260910_0001 (sin table_label).
-- CREATE OR REPLACE no puede QUITAR columnas: hay que dropear y recrear. La
-- vista no tiene dependientes en el repo; si en la BD viva los tuviera, el
-- DROP falla y no cambia nada.

begin;

drop view if exists public.sales_documents;

create or replace view public.sales_documents
with (security_invoker = on) as
  select
    fd.id,
    fd.business_id,
    fd.order_id,
    fd.payment_id,
    fd.check_id,
    fd.ncf_number,
    fd.ncf_type::text                  as ncf_type,
    fd.customer_name,
    fd.customer_rnc,
    coalesce(fd.subtotal, 0)           as subtotal,
    coalesce(fd.taxable_amount, 0)     as taxable_amount,
    coalesce(fd.itbis_amount, 0)       as itbis_amount,
    coalesce(fd.service_fee, 0)        as service_fee,
    coalesce(fd.total, 0)              as total,
    fd.status,
    fd.ecf_status,
    coalesce(fd.is_electronic, false)  as is_electronic,
    fd.created_at,
    'fiscal'::text                     as doc_kind
  from public.fiscal_documents fd
  union all
  select
    sn.id,
    sn.business_id,
    sn.order_id,
    sn.payment_id,
    sn.check_id,
    sn.note_number                     as ncf_number,
    -- 'NV' NO es un código DGII: es la marca interna de "nota de venta". La
    -- app la traduce a "Nota de Venta" en el catálogo de tipos.
    'NV'::text                         as ncf_type,
    sn.customer_name,
    sn.customer_rnc,
    sn.subtotal,
    -- Una nota no declara, pero sí cobró impuesto: el desglose se conserva
    -- para que el ticket y el detalle cuadren igual que una factura.
    sn.subtotal                        as taxable_amount,
    sn.tax                             as itbis_amount,
    sn.service_fee,
    sn.total,
    sn.status,
    null::text                         as ecf_status,
    false                              as is_electronic,
    sn.created_at,
    'sales_note'::text                 as doc_kind
  from public.sales_notes sn;

notify pgrst, 'reload schema';

commit;
