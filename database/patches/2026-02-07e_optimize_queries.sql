-- Optimización de indices para evitar Timeouts en lectura de items y pagos
-- Ejecutar para mejorar rendimiento de 'Obtener Items de Orden' y similares.
-- Fecha: 2026-02-07

-- 1. Índice simple para búsquedas de items por orden (Fundamental para getOrderItems)
CREATE INDEX IF NOT EXISTS idx_order_items_order_id 
ON public.order_items(order_id);

-- 2. Índice para la relación con modificadores (Fundamental para el join select(*, order_item_modifiers(*)))
CREATE INDEX IF NOT EXISTS idx_order_item_modifiers_item_id 
ON public.order_item_modifiers(item_id);

-- 3. Índice para acelerar la búsqueda de checks por orden
CREATE INDEX IF NOT EXISTS idx_order_checks_order_id 
ON public.order_checks(order_id);

-- 4. Asegurar índice en payments por orden (ya sugerido antes, reforzamos)
CREATE INDEX IF NOT EXISTS idx_payments_order_id 
ON public.payments(order_id);

-- 5. ANALYZE para actualizar estadísticas del planificador
ANALYZE public.order_items;
ANALYZE public.order_item_modifiers;
