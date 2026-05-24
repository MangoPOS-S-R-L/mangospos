-- ═══════════════════════════════════════════════════════════════════════════
-- WIPE TRANSACTIONAL DATA — businessId 038bf561-b346-43e8-8dee-25fc84c0fc29
-- ═══════════════════════════════════════════════════════════════════════════
--
-- USO:
--   1. Abrir Supabase Studio → SQL Editor
--   2. Pegar este script COMPLETO
--   3. Ejecutar — corre dentro de transaccion (BEGIN/ROLLBACK al final)
--      → veras los counts pero NO se aplica nada todavia
--   4. Revisar los counts del bloque "VERIFICACION POST-DELETE"
--   5. Si todo se ve bien → cambiar la ultima linea de "ROLLBACK;" a "COMMIT;"
--      y ejecutar otra vez
--
-- NO TOCA: productos, categorias, menus, taxes, mesas/zonas, impresoras,
--          areas, clientes, empleados, usuarios, settings del negocio,
--          cash_registers (cajas fisicas — solo las SESIONES se borran).
--
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- Lock para que nadie escriba mientras corremos esto.
SET LOCAL lock_timeout = '5s';

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICACION PRE-DELETE — Antes de borrar nada, contamos que hay
-- ═══════════════════════════════════════════════════════════════════════════

\echo '── ANTES DE BORRAR ──'

SELECT 'orders'                  AS tabla, count(*)::text AS rows
FROM   public.orders o
JOIN   public.table_sessions ts ON ts.id = o.session_id
WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'order_items', count(*)::text
FROM   public.order_items oi
JOIN   public.orders o ON o.id = oi.order_id
JOIN   public.table_sessions ts ON ts.id = o.session_id
WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'payments', count(*)::text
FROM   public.payments p
JOIN   public.orders o ON o.id = p.order_id
JOIN   public.table_sessions ts ON ts.id = o.session_id
WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'fiscal_documents', count(*)::text
FROM   public.fiscal_documents fd
WHERE  fd.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'table_sessions', count(*)::text
FROM   public.table_sessions ts
WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'cash_register_sessions', count(*)::text
FROM   public.cash_register_sessions crs
WHERE  crs.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'cash_transactions', count(*)::text
FROM   public.cash_transactions ct
JOIN   public.cash_register_sessions crs ON crs.id = ct.session_id
WHERE  crs.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'inventory_movements (de ventas)', count(*)::text
FROM   public.inventory_movements im
WHERE  im.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
  AND  im.reference_type IN ('order', 'sale', 'order_item')
UNION ALL SELECT 'print_jobs', count(*)::text
FROM   public.print_jobs pj
WHERE  pj.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29';

-- ═══════════════════════════════════════════════════════════════════════════
-- DELETES — orden FK-safe: hijos → padres
-- ═══════════════════════════════════════════════════════════════════════════

-- 1. fiscal_document_items (hijos de fiscal_documents)
DELETE FROM public.fiscal_document_items
WHERE  fiscal_document_id IN (
  SELECT id FROM public.fiscal_documents
  WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 2. fiscal_documents (NCFs emitidos) — ⚠️ DGII no lo sabe, este script
--    asume entorno test/dev sin reporte fiscal real
DELETE FROM public.fiscal_documents
WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29';

-- 3. cash_transactions (movimientos de caja generados por payments)
DELETE FROM public.cash_transactions
WHERE  session_id IN (
  SELECT id FROM public.cash_register_sessions
  WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 4. credit_payments (pagos con credito de cliente)
DELETE FROM public.credit_payments
WHERE  payment_id IN (
  SELECT p.id FROM public.payments p
  JOIN   public.orders o ON o.id = p.order_id
  JOIN   public.table_sessions ts ON ts.id = o.session_id
  WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 5. gift_card_transactions de ventas
DELETE FROM public.gift_card_transactions
WHERE  order_id IN (
  SELECT o.id FROM public.orders o
  JOIN   public.table_sessions ts ON ts.id = o.session_id
  WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 6. point_transactions (puntos de fidelidad ganados/redimidos)
DELETE FROM public.point_transactions
WHERE  order_id IN (
  SELECT o.id FROM public.orders o
  JOIN   public.table_sessions ts ON ts.id = o.session_id
  WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 7. payments (cobros)
DELETE FROM public.payments
WHERE  order_id IN (
  SELECT o.id FROM public.orders o
  JOIN   public.table_sessions ts ON ts.id = o.session_id
  WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 8. order_item_tax_lines (impuestos snapshot por item)
--    Si tu DB no tiene esta tabla, comenta este DELETE.
DELETE FROM public.order_item_tax_lines
WHERE  order_item_id IN (
  SELECT oi.id FROM public.order_items oi
  JOIN   public.orders o ON o.id = oi.order_id
  JOIN   public.table_sessions ts ON ts.id = o.session_id
  WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 9. order_item_modifiers
DELETE FROM public.order_item_modifiers
WHERE  item_id IN (
  SELECT oi.id FROM public.order_items oi
  JOIN   public.orders o ON o.id = oi.order_id
  JOIN   public.table_sessions ts ON ts.id = o.session_id
  WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 10. order_items
DELETE FROM public.order_items
WHERE  order_id IN (
  SELECT o.id FROM public.orders o
  JOIN   public.table_sessions ts ON ts.id = o.session_id
  WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 11. order_checks (cuentas/splits por order)
DELETE FROM public.order_checks
WHERE  order_id IN (
  SELECT o.id FROM public.orders o
  JOIN   public.table_sessions ts ON ts.id = o.session_id
  WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 12. orders
DELETE FROM public.orders
WHERE  session_id IN (
  SELECT id FROM public.table_sessions
  WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
);

-- 13. table_sessions
DELETE FROM public.table_sessions
WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29';

-- 14. print_jobs (historial de impresion)
DELETE FROM public.print_jobs
WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29';

-- 15. inventory_movements GENERADOS por ventas (no ajustes manuales ni compras)
--    Conserva movimientos de tipo 'adjustment_*', 'purchase_*', 'transfer_*'.
DELETE FROM public.inventory_movements
WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
  AND  reference_type IN ('order', 'sale', 'order_item');

-- 16. cash_register_sessions (sesiones de caja del negocio)
--    NO toca cash_registers (las "cajas" fisicas).
DELETE FROM public.cash_register_sessions
WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29';

-- 17. Reset estado de mesas a 'available' (por si quedaron ocupadas)
UPDATE public.dining_tables dt
SET    state = 'available'
FROM   public.zones z
WHERE  dt.zone_id = z.id
  AND  z.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
  AND  dt.state != 'available';

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICACION POST-DELETE — Tienen que ser todos 0
-- ═══════════════════════════════════════════════════════════════════════════

\echo '── DESPUES DE BORRAR (deberia ser todo 0) ──'

SELECT 'orders'                  AS tabla, count(*)::text AS rows
FROM   public.orders o
JOIN   public.table_sessions ts ON ts.id = o.session_id
WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'order_items', count(*)::text
FROM   public.order_items oi
JOIN   public.orders o ON o.id = oi.order_id
JOIN   public.table_sessions ts ON ts.id = o.session_id
WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'payments', count(*)::text
FROM   public.payments p
JOIN   public.orders o ON o.id = p.order_id
JOIN   public.table_sessions ts ON ts.id = o.session_id
WHERE  ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'fiscal_documents', count(*)::text
FROM   public.fiscal_documents
WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'table_sessions', count(*)::text
FROM   public.table_sessions
WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'cash_register_sessions', count(*)::text
FROM   public.cash_register_sessions
WHERE  business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29';

\echo '── PRODUCTOS / MENUS / TAXES (NO DEBEN HABER CAMBIADO) ──'

SELECT 'menu_items',  count(*)::text
FROM   public.menu_items WHERE business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'menu_categories', count(*)::text
FROM   public.menu_categories WHERE business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'taxes', count(*)::text
FROM   public.taxes WHERE business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'dining_tables (via zones)', count(*)::text
FROM   public.dining_tables dt
JOIN   public.zones z ON z.id = dt.zone_id
WHERE  z.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
UNION ALL SELECT 'customers', count(*)::text
FROM   public.customers WHERE business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29';

-- ═══════════════════════════════════════════════════════════════════════════
-- FINAL: dejar en ROLLBACK por defecto.
-- Cuando confirmes que los counts post-delete son 0 y los productos siguen
-- intactos, cambia esta linea a "COMMIT;" y ejecutalo de nuevo.
-- ═══════════════════════════════════════════════════════════════════════════

ROLLBACK;
-- COMMIT;
