-- =============================================================================
-- DELETE BUSINESS — script destructivo
-- =============================================================================
-- Borra TODOS los datos de un negocio respetando el orden de las FK.
-- Útil para limpiar businesses de prueba o duplicados.
--
-- ⚠️  ANTES DE EJECUTAR:
--   1. CONFIRMA el business_id correcto. NO se puede revertir tras COMMIT.
--   2. Haz BACKUP del proyecto Supabase si es producción.
--   3. Ejecuta primero la SECCIÓN PREVIEW (con SELECTs) y revisa los counts.
--   4. Si estás conforme, descomenta y ejecuta la SECCIÓN DELETE.
--
-- Uso:
--   - Reemplaza el business_id en las dos variables :business_id (parte
--     superior). Hay 2 versiones del script: PREVIEW y DELETE.
--   - PREVIEW devuelve counts sin tocar nada.
--   - DELETE corre todo en una transacción atómica (BEGIN…COMMIT).
--   - Si algo falla en el medio, hace ROLLBACK automático y nada se borra.
-- =============================================================================

-- Reemplaza este UUID con el business_id objetivo:
--   034e0121-d5af-4122-84f9-2d0cfec349a7

-- =============================================================================
-- SECCIÓN A — PREVIEW (no destructivo)
-- =============================================================================
-- Corre esto primero para ver cuántas filas afectaría el delete.
-- Si los números te parecen bien, pasa a la SECCIÓN B.

\set business_id '\'034e0121-d5af-4122-84f9-2d0cfec349a7\''

SELECT 'businesses'                  AS tabla, COUNT(*) FROM public.businesses                 WHERE id = :business_id::uuid
UNION ALL SELECT 'user_businesses',          COUNT(*) FROM public.user_businesses        WHERE business_id = :business_id::uuid
UNION ALL SELECT 'business_settings',        COUNT(*) FROM public.business_settings      WHERE business_id = :business_id::uuid
UNION ALL SELECT 'fiscal_settings',          COUNT(*) FROM public.fiscal_settings        WHERE business_id = :business_id::uuid
UNION ALL SELECT 'currencies',               COUNT(*) FROM public.currencies             WHERE business_id = :business_id::uuid
UNION ALL SELECT 'taxes',                    COUNT(*) FROM public.taxes                  WHERE business_id = :business_id::uuid
UNION ALL SELECT 'ncf_sequences',            COUNT(*) FROM public.ncf_sequences          WHERE business_id = :business_id::uuid
UNION ALL SELECT 'payment_methods',          COUNT(*) FROM public.payment_methods        WHERE business_id = :business_id::uuid
UNION ALL SELECT 'customers',                COUNT(*) FROM public.customers              WHERE business_id = :business_id::uuid
UNION ALL SELECT 'coupons',                  COUNT(*) FROM public.coupons                WHERE business_id = :business_id::uuid
UNION ALL SELECT 'gift_cards',               COUNT(*) FROM public.gift_cards             WHERE business_id = :business_id::uuid
UNION ALL SELECT 'loyalty_programs',         COUNT(*) FROM public.loyalty_programs       WHERE business_id = :business_id::uuid
UNION ALL SELECT 'memberships',              COUNT(*) FROM public.memberships            WHERE business_id = :business_id::uuid
UNION ALL SELECT 'promotions',               COUNT(*) FROM public.promotions             WHERE business_id = :business_id::uuid
UNION ALL SELECT 'categories',               COUNT(*) FROM public.categories             WHERE business_id = :business_id::uuid
UNION ALL SELECT 'menus',                    COUNT(*) FROM public.menus                  WHERE business_id = :business_id::uuid
UNION ALL SELECT 'menu_items',               COUNT(*) FROM public.menu_items             WHERE business_id = :business_id::uuid
UNION ALL SELECT 'modifier_groups',          COUNT(*) FROM public.modifier_groups        WHERE business_id = :business_id::uuid
UNION ALL SELECT 'modifiers',                COUNT(*) FROM public.modifiers              WHERE business_id = :business_id::uuid
UNION ALL SELECT 'inventory_items',          COUNT(*) FROM public.inventory_items        WHERE business_id = :business_id::uuid
UNION ALL SELECT 'inventory_movements',      COUNT(*) FROM public.inventory_movements    WHERE business_id = :business_id::uuid
UNION ALL SELECT 'warehouses',               COUNT(*) FROM public.warehouses             WHERE business_id = :business_id::uuid
UNION ALL SELECT 'suppliers',                COUNT(*) FROM public.suppliers              WHERE business_id = :business_id::uuid
UNION ALL SELECT 'purchase_orders',          COUNT(*) FROM public.purchase_orders        WHERE business_id = :business_id::uuid
UNION ALL SELECT 'zones',                    COUNT(*) FROM public.zones                  WHERE business_id = :business_id::uuid
UNION ALL SELECT 'table_sessions',           COUNT(*) FROM public.table_sessions         WHERE business_id = :business_id::uuid
UNION ALL SELECT 'orders (via sessions)',    COUNT(*) FROM public.orders o
                                              JOIN public.table_sessions ts ON ts.id = o.session_id
                                              WHERE ts.business_id = :business_id::uuid
UNION ALL SELECT 'payments',                 COUNT(*) FROM public.payments               WHERE business_id = :business_id::uuid
UNION ALL SELECT 'fiscal_documents',         COUNT(*) FROM public.fiscal_documents       WHERE business_id = :business_id::uuid
UNION ALL SELECT 'employees',                COUNT(*) FROM public.employees              WHERE business_id = :business_id::uuid
UNION ALL SELECT 'shifts',                   COUNT(*) FROM public.shifts                 WHERE business_id = :business_id::uuid
UNION ALL SELECT 'attendance',               COUNT(*) FROM public.attendance             WHERE business_id = :business_id::uuid
UNION ALL SELECT 'roles',                    COUNT(*) FROM public.roles                  WHERE business_id = :business_id::uuid
UNION ALL SELECT 'user_roles',               COUNT(*) FROM public.user_roles             WHERE business_id = :business_id::uuid
UNION ALL SELECT 'user_permission_overrides',COUNT(*) FROM public.user_permission_overrides WHERE business_id = :business_id::uuid
UNION ALL SELECT 'printers',                 COUNT(*) FROM public.printers               WHERE business_id = :business_id::uuid
UNION ALL SELECT 'print_areas',              COUNT(*) FROM public.print_areas            WHERE business_id = :business_id::uuid
UNION ALL SELECT 'print_area_printers',      COUNT(*) FROM public.print_area_printers    WHERE business_id = :business_id::uuid
UNION ALL SELECT 'print_jobs',               COUNT(*) FROM public.print_jobs             WHERE business_id = :business_id::uuid
UNION ALL SELECT 'cash_registers',           COUNT(*) FROM public.cash_registers         WHERE business_id = :business_id::uuid
UNION ALL SELECT 'customer_credits',         COUNT(*) FROM public.customer_credits       WHERE business_id = :business_id::uuid
ORDER BY 1;

-- =============================================================================
-- SECCIÓN B — DELETE (DESTRUCTIVO)
-- =============================================================================
-- Descomenta TODO el bloque de abajo y ejecútalo. Es atómico (BEGIN…COMMIT).
-- Si algo falla, hace ROLLBACK y nada se borra.

/*

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 0. Variables locales para no repetir el UUID
-- ───────────────────────────────────────────────────────────────────────────
\set business_id '\'034e0121-d5af-4122-84f9-2d0cfec349a7\''

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Hijos profundos: items, modifiers, tax_lines, checks
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.order_item_modifiers
 WHERE item_id IN (
   SELECT oi.id
     FROM public.order_items oi
     JOIN public.orders o          ON o.id = oi.order_id
     JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE ts.business_id = :business_id::uuid
 );

DELETE FROM public.order_item_tax_lines
 WHERE order_item_id IN (
   SELECT oi.id
     FROM public.order_items oi
     JOIN public.orders o          ON o.id = oi.order_id
     JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE ts.business_id = :business_id::uuid
 );

DELETE FROM public.order_items
 WHERE order_id IN (
   SELECT o.id
     FROM public.orders o
     JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE ts.business_id = :business_id::uuid
 );

DELETE FROM public.order_checks
 WHERE order_id IN (
   SELECT o.id
     FROM public.orders o
     JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE ts.business_id = :business_id::uuid
 );

-- ───────────────────────────────────────────────────────────────────────────
-- 2. Pagos / fiscales / cupones / lealtad referenciando orders
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.fiscal_documents WHERE business_id = :business_id::uuid;

DELETE FROM public.coupon_usage
 WHERE order_id IN (
   SELECT o.id FROM public.orders o
     JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE ts.business_id = :business_id::uuid
 );

DELETE FROM public.gift_card_transactions
 WHERE order_id IN (
   SELECT o.id FROM public.orders o
     JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE ts.business_id = :business_id::uuid
 );

DELETE FROM public.point_transactions
 WHERE order_id IN (
   SELECT o.id FROM public.orders o
     JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE ts.business_id = :business_id::uuid
 );

DELETE FROM public.customer_credits WHERE business_id = :business_id::uuid;
DELETE FROM public.payments         WHERE business_id = :business_id::uuid;

-- ───────────────────────────────────────────────────────────────────────────
-- 3. Cash register sessions y transacciones
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.cash_transactions
 WHERE session_id IN (
   SELECT crs.id FROM public.cash_register_sessions crs
     JOIN public.cash_registers cr ON cr.id = crs.cash_register_id
    WHERE cr.business_id = :business_id::uuid
 );

DELETE FROM public.credit_payments
 WHERE session_id IN (
   SELECT crs.id FROM public.cash_register_sessions crs
     JOIN public.cash_registers cr ON cr.id = crs.cash_register_id
    WHERE cr.business_id = :business_id::uuid
 );

DELETE FROM public.cash_register_sessions
 WHERE cash_register_id IN (
   SELECT id FROM public.cash_registers WHERE business_id = :business_id::uuid
 );

DELETE FROM public.cash_registers WHERE business_id = :business_id::uuid;

-- ───────────────────────────────────────────────────────────────────────────
-- 4. Orders + sesiones de mesa
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.orders
 WHERE session_id IN (
   SELECT id FROM public.table_sessions WHERE business_id = :business_id::uuid
 );

DELETE FROM public.table_sessions WHERE business_id = :business_id::uuid;

-- ───────────────────────────────────────────────────────────────────────────
-- 5. Mesas + zonas
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.dining_tables
 WHERE zone_id IN (
   SELECT id FROM public.zones WHERE business_id = :business_id::uuid
 );

DELETE FROM public.zones WHERE business_id = :business_id::uuid;

-- ───────────────────────────────────────────────────────────────────────────
-- 6. Inventario + compras + warehouses + suppliers
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.inventory_movements WHERE business_id = :business_id::uuid;

DELETE FROM public.inventory_stock
 WHERE item_id IN (
   SELECT id FROM public.inventory_items WHERE business_id = :business_id::uuid
 );

DELETE FROM public.recipe_ingredients
 WHERE inventory_item_id IN (
   SELECT id FROM public.inventory_items WHERE business_id = :business_id::uuid
 );

DELETE FROM public.purchase_order_items
 WHERE purchase_order_id IN (
   SELECT id FROM public.purchase_orders WHERE business_id = :business_id::uuid
 );

DELETE FROM public.purchase_orders WHERE business_id = :business_id::uuid;
DELETE FROM public.inventory_items WHERE business_id = :business_id::uuid;
DELETE FROM public.warehouses      WHERE business_id = :business_id::uuid;
DELETE FROM public.suppliers       WHERE business_id = :business_id::uuid;

-- ───────────────────────────────────────────────────────────────────────────
-- 7. Menú: recetas, links, taxes, groups, modifiers, items, menus, categorías
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.recipes
 WHERE menu_item_id IN (
   SELECT id FROM public.menu_items WHERE business_id = :business_id::uuid
 );

DELETE FROM public.menu_item_links
 WHERE item_id IN (
   SELECT id FROM public.menu_items WHERE business_id = :business_id::uuid
 );

DELETE FROM public.menu_item_taxes
 WHERE item_id IN (
   SELECT id FROM public.menu_items WHERE business_id = :business_id::uuid
 );

DELETE FROM public.menu_item_groups
 WHERE menu_item_id IN (
   SELECT id FROM public.menu_items WHERE business_id = :business_id::uuid
 );

DELETE FROM public.modifiers       WHERE business_id = :business_id::uuid;
DELETE FROM public.modifier_groups WHERE business_id = :business_id::uuid;
DELETE FROM public.menu_items      WHERE business_id = :business_id::uuid;
DELETE FROM public.menus           WHERE business_id = :business_id::uuid;
DELETE FROM public.categories      WHERE business_id = :business_id::uuid;

-- ───────────────────────────────────────────────────────────────────────────
-- 8. Empleados + roles + permisos
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.employee_benefits
 WHERE employee_id IN (
   SELECT id FROM public.employees WHERE business_id = :business_id::uuid
 );

DELETE FROM public.employee_roles
 WHERE employee_id IN (
   SELECT id FROM public.employees WHERE business_id = :business_id::uuid
 );

DELETE FROM public.attendance WHERE business_id = :business_id::uuid;
DELETE FROM public.shifts     WHERE business_id = :business_id::uuid;
DELETE FROM public.employees  WHERE business_id = :business_id::uuid;

DELETE FROM public.user_permission_overrides WHERE business_id = :business_id::uuid;
DELETE FROM public.user_roles                WHERE business_id = :business_id::uuid;
DELETE FROM public.role_permissions
 WHERE role_id IN (SELECT id FROM public.roles WHERE business_id = :business_id::uuid);
DELETE FROM public.roles                     WHERE business_id = :business_id::uuid;

-- ───────────────────────────────────────────────────────────────────────────
-- 9. Impresión
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.print_jobs          WHERE business_id = :business_id::uuid;
DELETE FROM public.print_area_printers WHERE business_id = :business_id::uuid;
DELETE FROM public.print_areas         WHERE business_id = :business_id::uuid;
DELETE FROM public.printers            WHERE business_id = :business_id::uuid;

-- ───────────────────────────────────────────────────────────────────────────
-- 10. Otras tablas con business_id directo
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.customers         WHERE business_id = :business_id::uuid;
DELETE FROM public.coupons           WHERE business_id = :business_id::uuid;
DELETE FROM public.gift_cards        WHERE business_id = :business_id::uuid;
DELETE FROM public.loyalty_programs  WHERE business_id = :business_id::uuid;
DELETE FROM public.memberships       WHERE business_id = :business_id::uuid;
DELETE FROM public.promotions        WHERE business_id = :business_id::uuid;
DELETE FROM public.payment_methods   WHERE business_id = :business_id::uuid;
DELETE FROM public.taxes             WHERE business_id = :business_id::uuid;
DELETE FROM public.ncf_sequences     WHERE business_id = :business_id::uuid;
DELETE FROM public.currencies        WHERE business_id = :business_id::uuid;
DELETE FROM public.fiscal_settings   WHERE business_id = :business_id::uuid;
DELETE FROM public.business_settings WHERE business_id = :business_id::uuid;
DELETE FROM public.user_businesses   WHERE business_id = :business_id::uuid;

-- ───────────────────────────────────────────────────────────────────────────
-- 11. Finalmente el business mismo
-- ───────────────────────────────────────────────────────────────────────────
DELETE FROM public.businesses WHERE id = :business_id::uuid;

-- Verificación: estos counts deben ser 0
SELECT 'businesses restante' AS check, COUNT(*)
  FROM public.businesses WHERE id = :business_id::uuid;

COMMIT;

*/

-- =============================================================================
-- Si después del COMMIT te das cuenta que algo salió mal:
--   - NO hay cómo deshacer.
--   - Restaurar desde backup de Supabase.
--
-- Si vas a probar, ejecuta primero PREVIEW. Si los counts cuadran, descomenta
-- la sección B y ejecútala. La transacción es atómica: si falla en el medio,
-- automáticamente hace ROLLBACK y no se borra nada.
-- =============================================================================
