-- 🖨️ Script SQL para Configuración de Impresión por Departamentos
-- MangoPos - Sistema de Impresión

-- ============================================================
-- 1. AGREGAR CAMPO DE ÁREA DE IMPRESIÓN A MENU_ITEMS
-- ============================================================

-- Agregar columna para área de impresión en items del menú
ALTER TABLE menu_items 
ADD COLUMN IF NOT EXISTS print_area_code TEXT;

-- Crear índice para búsquedas rápidas
CREATE INDEX IF NOT EXISTS idx_menu_items_print_area 
ON menu_items(print_area_code) 
WHERE print_area_code IS NOT NULL;

-- Comentario explicativo
COMMENT ON COLUMN menu_items.print_area_code IS 
'Código del área de impresión: kitchen_hot, kitchen_cold, bar, cashier, etc.';

-- ============================================================
-- 2. FUNCIÓN PARA ASIGNAR ÁREA AUTOMÁTICAMENTE POR CATEGORÍA
-- ============================================================

CREATE OR REPLACE FUNCTION fn_assign_print_area_by_category()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  -- Asignar cocina caliente a carnes, pastas, etc.
  UPDATE menu_items mi
  SET print_area_code = 'kitchen_hot'
  FROM categories c
  WHERE mi.category_id = c.id
    AND c.name IN ('Carnes', 'Pastas', 'Platos Calientes', 'Sopas')
    AND mi.print_area_code IS NULL;

  -- Asignar cocina fría a ensaladas, postres, etc.
  UPDATE menu_items mi
  SET print_area_code = 'kitchen_cold'
  FROM categories c
  WHERE mi.category_id = c.id
    AND c.name IN ('Ensaladas', 'Postres', 'Entradas Frías')
    AND mi.print_area_code IS NULL;

  -- Asignar bar a bebidas
  UPDATE menu_items mi
  SET print_area_code = 'bar'
  FROM categories c
  WHERE mi.category_id = c.id
    AND c.name IN ('Bebidas', 'Cocteles', 'Cervezas', 'Vinos', 'Licores')
    AND mi.print_area_code IS NULL;

  -- Por defecto, asignar a cocina caliente
  UPDATE menu_items
  SET print_area_code = 'kitchen_hot'
  WHERE print_area_code IS NULL;

  RAISE NOTICE 'Áreas de impresión asignadas automáticamente';
END;
$$;

-- Ejecutar la función para asignar áreas
SELECT fn_assign_print_area_by_category();

-- ============================================================
-- 3. FUNCIÓN PARA OBTENER IMPRESORAS DE UN ÁREA
-- ============================================================

CREATE OR REPLACE FUNCTION fn_get_printers_for_area(
  p_area_code TEXT,
  p_business_id UUID
)
RETURNS TABLE (
  printer_id UUID,
  printer_name TEXT,
  printer_type TEXT,
  ip_address TEXT,
  port INTEGER,
  priority INTEGER,
  prints_orders BOOLEAN,
  prints_prebills BOOLEAN,
  prints_receipts BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.id AS printer_id,
    p.name AS printer_name,
    p.type AS printer_type,
    p.ip_address,
    p.port,
    pap.priority,
    pap.prints_orders,
    pap.prints_prebills,
    pap.prints_receipts
  FROM printers p
  INNER JOIN print_area_printers pap ON p.id = pap.printer_id
  INNER JOIN print_areas pa ON pap.area_id = pa.id
  WHERE pa.code = p_area_code
    AND pa.business_id = p_business_id
    AND p.is_active = true
    AND pap.enabled = true
  ORDER BY pap.priority DESC, p.name;
END;
$$;

-- ============================================================
-- 4. FUNCIÓN PARA CREAR TRABAJOS DE IMPRESIÓN POR ÁREA
-- ============================================================

CREATE OR REPLACE FUNCTION fn_create_print_jobs_for_order(
  p_order_id UUID
)
RETURNS TABLE (
  job_id UUID,
  area_code TEXT,
  item_count INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_business_id UUID;
  v_area_record RECORD;
  v_job_id UUID;
  v_order_data JSONB;
BEGIN
  -- Obtener business_id de la orden
  SELECT business_id INTO v_business_id
  FROM orders
  WHERE id = p_order_id;

  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'Orden no encontrada: %', p_order_id;
  END IF;

  -- Obtener datos de la orden para el ticket
  SELECT jsonb_build_object(
    'orderNumber', o.order_number,
    'tableName', COALESCE(dt.label, 'N/A'),
    'waiterName', COALESCE(u.full_name, 'N/A'),
    'peopleCount', COALESCE(ts.people_count, 1),
    'timestamp', NOW()
  ) INTO v_order_data
  FROM orders o
  LEFT JOIN table_sessions ts ON o.session_id = ts.id
  LEFT JOIN dining_tables dt ON ts.table_id = dt.id
  LEFT JOIN users u ON ts.user_id = u.id
  WHERE o.id = p_order_id;

  -- Agrupar items por área y crear trabajos de impresión
  FOR v_area_record IN
    SELECT 
      pa.id AS area_id,
      pa.code AS area_code,
      COUNT(oi.id) AS item_count,
      jsonb_agg(
        jsonb_build_object(
          'name', mi.name,
          'quantity', oi.quantity,
          'notes', oi.notes,
          'isTakeout', oi.is_takeout,
          'modifiers', (
            SELECT jsonb_agg(
              jsonb_build_object(
                'name', oim.modifier_name,
                'quantity', oim.quantity
              )
            )
            FROM order_item_modifiers oim
            WHERE oim.item_id = oi.id
          )
        )
      ) AS items
    FROM order_items oi
    INNER JOIN menu_items mi ON oi.menu_item_id = mi.id
    LEFT JOIN print_areas pa ON mi.print_area_code = pa.code AND pa.business_id = v_business_id
    WHERE oi.order_id = p_order_id
      AND oi.status != 'voided'
    GROUP BY pa.id, pa.code
  LOOP
    -- Crear trabajo de impresión
    INSERT INTO print_jobs (
      business_id,
      area_id,
      order_id,
      type,
      status,
      data
    ) VALUES (
      v_business_id,
      v_area_record.area_id,
      p_order_id,
      'kitchen_order',
      'pending',
      v_order_data || jsonb_build_object('items', v_area_record.items)
    )
    RETURNING id INTO v_job_id;

    -- Retornar información del job creado
    job_id := v_job_id;
    area_code := v_area_record.area_code;
    item_count := v_area_record.item_count;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- ============================================================
-- 5. TRIGGER PARA CREAR JOBS AUTOMÁTICAMENTE AL ENVIAR A COCINA
-- ============================================================

CREATE OR REPLACE FUNCTION trg_create_print_jobs_on_send_to_kitchen()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Solo crear jobs cuando el estado cambia a 'confirmed'
  IF NEW.status = 'confirmed' AND OLD.status != 'confirmed' THEN
    -- Crear trabajos de impresión
    PERFORM fn_create_print_jobs_for_order(NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

-- Crear trigger si no existe
DROP TRIGGER IF EXISTS trg_order_send_to_kitchen ON orders;
CREATE TRIGGER trg_order_send_to_kitchen
  AFTER UPDATE ON orders
  FOR EACH ROW
  EXECUTE FUNCTION trg_create_print_jobs_on_send_to_kitchen();

-- ============================================================
-- 6. VISTA PARA MONITOREAR TRABAJOS DE IMPRESIÓN
-- ============================================================

CREATE OR REPLACE VIEW v_print_jobs_monitor AS
SELECT 
  pj.id,
  pj.business_id,
  pa.name AS area_name,
  pa.code AS area_code,
  o.order_number,
  dt.label AS table_name,
  pj.type,
  pj.status,
  p.name AS printer_name,
  pj.retry_count,
  pj.error_message,
  pj.created_at,
  pj.printed_at,
  EXTRACT(EPOCH FROM (NOW() - pj.created_at))::INTEGER AS age_seconds
FROM print_jobs pj
LEFT JOIN print_areas pa ON pj.area_id = pa.id
LEFT JOIN orders o ON pj.order_id = o.id
LEFT JOIN table_sessions ts ON o.session_id = ts.id
LEFT JOIN dining_tables dt ON ts.table_id = dt.id
LEFT JOIN printers p ON pj.printer_id = p.id
ORDER BY pj.created_at DESC;

-- ============================================================
-- 7. FUNCIÓN PARA LIMPIAR TRABAJOS ANTIGUOS
-- ============================================================

CREATE OR REPLACE FUNCTION fn_cleanup_old_print_jobs(
  p_days_old INTEGER DEFAULT 7
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_deleted_count INTEGER;
BEGIN
  -- Eliminar trabajos impresos hace más de X días
  DELETE FROM print_jobs
  WHERE status = 'printed'
    AND printed_at < NOW() - (p_days_old || ' days')::INTERVAL;
  
  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  
  RAISE NOTICE 'Eliminados % trabajos de impresión antiguos', v_deleted_count;
  
  RETURN v_deleted_count;
END;
$$;

-- ============================================================
-- 8. DATOS DE EJEMPLO - ÁREAS PREDETERMINADAS
-- ============================================================

-- Función para crear áreas predeterminadas para un negocio
CREATE OR REPLACE FUNCTION fn_create_default_print_areas(
  p_business_id UUID
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  -- Cocina Caliente
  INSERT INTO print_areas (business_id, name, code, is_active)
  VALUES (p_business_id, 'Cocina Caliente', 'kitchen_hot', true)
  ON CONFLICT (business_id, code) DO NOTHING;

  -- Cocina Fría
  INSERT INTO print_areas (business_id, name, code, is_active)
  VALUES (p_business_id, 'Cocina Fría', 'kitchen_cold', true)
  ON CONFLICT (business_id, code) DO NOTHING;

  -- Bar
  INSERT INTO print_areas (business_id, name, code, is_active)
  VALUES (p_business_id, 'Bar', 'bar', true)
  ON CONFLICT (business_id, code) DO NOTHING;

  -- Caja
  INSERT INTO print_areas (business_id, name, code, is_active)
  VALUES (p_business_id, 'Caja', 'cashier', true)
  ON CONFLICT (business_id, code) DO NOTHING;

  -- Fiscal
  INSERT INTO print_areas (business_id, name, code, is_active)
  VALUES (p_business_id, 'Fiscal', 'fiscal', true)
  ON CONFLICT (business_id, code) DO NOTHING;

  RAISE NOTICE 'Áreas de impresión predeterminadas creadas para business_id: %', p_business_id;
END;
$$;

-- ============================================================
-- 9. ÍNDICES PARA OPTIMIZACIÓN
-- ============================================================

-- Índice para búsqueda de trabajos pendientes
CREATE INDEX IF NOT EXISTS idx_print_jobs_status_created 
ON print_jobs(business_id, status, created_at DESC)
WHERE status IN ('pending', 'printing');

-- Índice para búsqueda por área
CREATE INDEX IF NOT EXISTS idx_print_jobs_area 
ON print_jobs(area_id, status);

-- Índice para búsqueda por orden
CREATE INDEX IF NOT EXISTS idx_print_jobs_order 
ON print_jobs(order_id);

-- Índice para asignaciones activas
CREATE INDEX IF NOT EXISTS idx_print_area_printers_active 
ON print_area_printers(area_id, enabled)
WHERE enabled = true;

-- ============================================================
-- 10. COMENTARIOS Y DOCUMENTACIÓN
-- ============================================================

COMMENT ON TABLE print_areas IS 
'Áreas de impresión (departamentos): cocina, bar, caja, etc.';

COMMENT ON TABLE print_area_printers IS 
'Asignación de impresoras a áreas con configuración de tipos de documentos';

COMMENT ON TABLE print_jobs IS 
'Cola de trabajos de impresión pendientes, en proceso o completados';

COMMENT ON FUNCTION fn_create_print_jobs_for_order(UUID) IS 
'Crea trabajos de impresión agrupados por área para una orden';

COMMENT ON FUNCTION fn_get_printers_for_area(TEXT, UUID) IS 
'Obtiene impresoras activas asignadas a un área específica';

-- ============================================================
-- ✅ SCRIPT COMPLETADO
-- ============================================================

-- Para ejecutar este script:
-- 1. Conéctate a tu base de datos de Supabase
-- 2. Ve al SQL Editor
-- 3. Copia y pega este script
-- 4. Ejecuta

-- Para crear áreas predeterminadas para tu negocio:
-- SELECT fn_create_default_print_areas('tu-business-id-aqui');

-- Para asignar áreas automáticamente a items existentes:
-- SELECT fn_assign_print_area_by_category();

-- Para limpiar trabajos antiguos (ejecutar periódicamente):
-- SELECT fn_cleanup_old_print_jobs(7); -- Eliminar trabajos de hace más de 7 días
