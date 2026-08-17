-- =============================================================================
-- PRD Compras (lector de barras y cuentas por pagar) — §8 Modelo de datos.
--
-- CONTEXTO:
--   El registro de compra guardaba un solo `invoice_number`, cuyo texto de
--   ayuda invitaba a escribir ahí el NCF. Son dos identificadores distintos
--   con dueños distintos: el número de factura lo asigna el proveedor y sirve
--   para reclamarle; el NCF es el comprobante fiscal con el que se sustenta
--   el crédito de ITBIS ante la DGII. Meterlos en la misma columna obliga a
--   elegir cuál se pierde.
--
--   Además, el vencimiento de una cuenta por pagar no podía derivarse de las
--   condiciones del proveedor, porque `suppliers.payment_terms` es texto libre
--   («30 días», «contado», «50% anticipo»). Se añade un campo numérico que
--   convive con el texto: el número alimenta el vencimiento por defecto y el
--   texto se conserva para los casos que no son un plazo simple.
--
-- ENTREGA:
--   1. purchase_orders.ncf      varchar(20) nulo + índice (business_id, ncf)
--   2. supplier_credits.ncf     varchar(20) nulo (copia al crear la CxP)
--   3. suppliers.payment_terms_days smallint nulo
--   4. Migración de datos ADITIVA: copia a `ncf` únicamente los
--      `invoice_number` que satisfacen el patrón de NCF y los DEJA también en
--      `invoice_number`. No borra nada. Reclasificar el resto es trabajo
--      manual del negocio, no de una migración adivinando.
--
-- IDEMPOTENTE: sí (`if not exists` en todo; el update ignora lo ya copiado).
-- REVERSIBLE: sí (ver _ROLLBACK). Ninguna columna existente se modifica.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. NCF en la orden de compra
-- ---------------------------------------------------------------------------
alter table public.purchase_orders
  add column if not exists ncf varchar(20);

comment on column public.purchase_orders.ncf is
  'Comprobante fiscal (NCF/e-CF) de la factura del proveedor. Opcional: no '
  'toda compra legítima trae comprobante. Distinto de invoice_number, que es '
  'el número propio de la factura del proveedor.';

create index if not exists idx_purchase_orders_business_ncf
  on public.purchase_orders (business_id, ncf)
  where ncf is not null;

-- ---------------------------------------------------------------------------
-- 2. NCF en la cuenta por pagar (copia, para consultarla sin volver a la orden)
-- ---------------------------------------------------------------------------
alter table public.supplier_credits
  add column if not exists ncf varchar(20);

comment on column public.supplier_credits.ncf is
  'Copia del NCF de la orden al crear la CxP, para que la deuda sea '
  'consultable sin volver a la compra.';

-- ---------------------------------------------------------------------------
-- 3. Días de plazo del proveedor (convive con payment_terms de texto libre)
-- ---------------------------------------------------------------------------
alter table public.suppliers
  add column if not exists payment_terms_days smallint;

comment on column public.suppliers.payment_terms_days is
  'Días de plazo del proveedor. Alimenta el vencimiento por defecto de la '
  'cuenta por pagar. Convive con payment_terms (texto libre), que NO se '
  'elimina: el texto cubre los casos que no son un plazo simple.';

-- ---------------------------------------------------------------------------
-- 4. Migración de datos: solo lo que INEQUÍVOCAMENTE es un NCF
--    Patrón DGII: serie B (NCF) o E (e-CF) + 2 dígitos de tipo + 8 a 10 de
--    secuencia. Ej. B0100000284 (11) / E310000000001 (13).
-- ---------------------------------------------------------------------------
update public.purchase_orders
   set ncf = upper(regexp_replace(invoice_number, '\s', '', 'g'))
 where ncf is null
   and invoice_number is not null
   and upper(regexp_replace(invoice_number, '\s', '', 'g')) ~ '^[BE][0-9]{2}[0-9]{8,10}$';

commit;
