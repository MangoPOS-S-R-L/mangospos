-- =====================================================================
-- Vender SIN inventario — 2 negocios
--
-- Objetivo: que TODOS los productos de estos 2 negocios se puedan vender
-- siempre, sin requerir stock. Se logra desactivando el tracking de
-- inventario por producto (menu_items.is_inventory_tracked = false):
--   - Nunca se auto-desactivan por stock 0 (auto-86 ignora los no-tracked).
--   - Nunca descuentan inventario al vender.
--   - Quedan siempre disponibles en el catálogo del cajero.
-- (El inventario usa un DOBLE gate: business_settings.inventory_mode +
--  menu_items.is_inventory_tracked. Con is_inventory_tracked = false el
--  producto queda fuera del control de stock sin importar el modo.)
--
-- Negocios:
--   af2ec2e7-2cdd-4583-bf5a-7e7476173b72
--   f054fbc2-3fb7-4e34-a020-11341ff11d84
--
-- Ejecutar UNA vez en el SQL Editor de Supabase (prod).
-- Idempotente: re-ejecutar no cambia nada (ya quedan en false / activos).
-- =====================================================================

-- ------------------------------------------------------------------
-- 1) ANTES — foto del estado actual (corre este SELECT primero)
-- ------------------------------------------------------------------
SELECT business_id,
       count(*)                                          AS total_productos,
       count(*) FILTER (WHERE is_inventory_tracked)      AS con_tracking,
       count(*) FILTER (WHERE NOT is_inventory_tracked)  AS sin_tracking,
       count(*) FILTER (WHERE auto_disabled)             AS auto_86
FROM menu_items
WHERE business_id IN (
  'af2ec2e7-2cdd-4583-bf5a-7e7476173b72',
  'f054fbc2-3fb7-4e34-a020-11341ff11d84'
)
GROUP BY business_id;

-- ------------------------------------------------------------------
-- 2) CAMBIO — dentro de una transacción
-- ------------------------------------------------------------------
BEGIN;

-- 2a) Desactivar el tracking de stock en todos los productos.
UPDATE menu_items
   SET is_inventory_tracked = false,
       updated_at = now()
 WHERE business_id IN (
   'af2ec2e7-2cdd-4583-bf5a-7e7476173b72',
   'f054fbc2-3fb7-4e34-a020-11341ff11d84'
 )
   AND is_inventory_tracked = true;   -- solo las que faltan (idempotente)

-- 2b) Reactivar los productos que el auto-86 apagó por stock 0.
--     SOLO toca los desactivados automáticamente (auto_disabled = true);
--     nunca los que el dueño apagó a mano.
UPDATE menu_items
   SET is_active     = true,
       auto_disabled = false,
       updated_at    = now()
 WHERE business_id IN (
   'af2ec2e7-2cdd-4583-bf5a-7e7476173b72',
   'f054fbc2-3fb7-4e34-a020-11341ff11d84'
 )
   AND auto_disabled = true;

COMMIT;

-- ------------------------------------------------------------------
-- 3) DESPUÉS — verificación (con_tracking y auto_86 deben quedar en 0)
-- ------------------------------------------------------------------
SELECT business_id,
       count(*)                                          AS total_productos,
       count(*) FILTER (WHERE is_inventory_tracked)      AS con_tracking,
       count(*) FILTER (WHERE NOT is_inventory_tracked)  AS sin_tracking,
       count(*) FILTER (WHERE auto_disabled)             AS auto_86
FROM menu_items
WHERE business_id IN (
  'af2ec2e7-2cdd-4583-bf5a-7e7476173b72',
  'f054fbc2-3fb7-4e34-a020-11341ff11d84'
)
GROUP BY business_id;
