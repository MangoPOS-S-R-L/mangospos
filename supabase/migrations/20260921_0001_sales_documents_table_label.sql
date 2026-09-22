-- =============================================================================
-- 20260921_0001 — Historial de ventas: la MESA de cada documento
-- =============================================================================
--
-- PEDIDO: en "Historial de ventas", en vez del número de documento (RNC/
-- cédula del cliente) mostrar la mesa, y poder BUSCAR por el nombre de la
-- mesa ("MUEBLE12").
--
-- POR QUÉ HACE FALTA LA BD PARA BUSCAR (y no para mostrar):
--   Mostrar la mesa lo hace la app sola: ya resuelve orden → sesión → mesa
--   para las filas de cada página. Pero la BÚSQUEDA corre en el servidor
--   sobre la vista `sales_documents`, con paginación y conteo. Si la mesa
--   no está en la vista, la única forma sería traer primero todas las
--   órdenes de esa mesa y meterlas en un `in (...)`: con meses de historia
--   eso revienta la URL (414, ver el caso de inFilter sin trocear) y rompe el
--   conteo de páginas. Con la columna en la vista, buscar por mesa es un
--   `ilike` más y la paginación sigue exacta.
--
-- QUÉ HACE:
--   Agrega `table_label` AL FINAL de `sales_documents` (CREATE OR REPLACE
--   solo permite columnas nuevas al final, con las existentes idénticas):
--   la etiqueta de la mesa (o su código). Null en venta rápida, manual o
--   delivery, que no tienen mesa.
--
-- SEGURIDAD: la vista sigue siendo `security_invoker`: aplica el RLS de
--   quien consulta. Los joins son LEFT, así que una mesa que el RLS no deja
--   ver solo deja la columna en null; nunca esconde el documento.
--
-- NO toca datos. IDEMPOTENTE. ROLLBACK: ..._ROLLBACK.sql (vista original de
-- 20260910_0001). Si la vista viva difiere del repo, el CREATE OR REPLACE
-- falla entero y no cambia nada.
-- =============================================================================

begin;

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
    'fiscal'::text                     as doc_kind,
    -- NUEVA (20260921_0001): la mesa del documento.
    coalesce(nullif(trim(dt.label), ''), nullif(trim(dt.code), ''))
                                       as table_label
  from public.fiscal_documents fd
  left join public.orders o          on o.id = fd.order_id
  left join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt  on dt.id = ts.table_id
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
    'sales_note'::text                 as doc_kind,
    coalesce(nullif(trim(dt.label), ''), nullif(trim(dt.code), ''))
                                       as table_label
  from public.sales_notes sn
  left join public.orders o          on o.id = sn.order_id
  left join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt  on dt.id = ts.table_id;

comment on view public.sales_documents is
  'Comprobantes fiscales + notas de venta para el Historial de ventas. '
  '`table_label` (20260921_0001) = la mesa, para mostrarla y buscar por ella.';

notify pgrst, 'reload schema';

commit;

-- =============================================================================
-- VERIFICACIÓN (UNA sola fila; tiene que dar true):
--
--   select exists (
--     select 1 from information_schema.columns
--     where table_name = 'sales_documents' and column_name = 'table_label'
--   ) as tiene_mesa;
-- =============================================================================
