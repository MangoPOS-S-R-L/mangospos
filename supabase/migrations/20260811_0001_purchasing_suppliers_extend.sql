-- =============================================================================
-- PRD 6.1 · F1 — Suplidores: columnas aditivas para el bloque fiscal (606).
--
-- CONTEXTO:
--   La tabla `suppliers` YA existe (con rnc, contacto, payment_terms text) y
--   `purchase_orders.supplier_id` ya tiene su FK. El PRD 6.1 original proponía
--   crearla de cero; este archivo la corrige: solo agrega lo que falta.
--
-- ENTREGA:
--   - suppliers.tax_id_type: tipo de identificación para el 606
--     (rnc | cedula | pasaporte). El número vive en la columna `rnc` existente.
--   - suppliers.whatsapp: canal de envío de la OC (F2 manda la PO por WhatsApp).
--   - suppliers.payment_terms_days: término de pago numérico para vencimientos;
--     el `payment_terms` text existente se conserva como nota libre.
--
-- IDEMPOTENTE / BACKWARDS-COMPATIBLE:
--   - Solo `add column if not exists` con defaults inocuos.
--   - RLS existente intacta (sup_select: cualquier miembro; sup_admin:
--     owner/admin escriben).
-- =============================================================================

begin;

alter table public.suppliers
  add column if not exists tax_id_type text
    check (tax_id_type in ('rnc', 'cedula', 'pasaporte') or tax_id_type is null);

alter table public.suppliers
  add column if not exists whatsapp text;

alter table public.suppliers
  add column if not exists payment_terms_days int default 0 not null;

comment on column public.suppliers.tax_id_type is
  'Tipo de identificación fiscal para el reporte 606: rnc | cedula | pasaporte. '
  'El número está en la columna rnc.';

comment on column public.suppliers.payment_terms_days is
  'Término de pago en días (0 = contado). payment_terms (text) queda como nota libre.';

commit;
