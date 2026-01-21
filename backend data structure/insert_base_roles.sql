-- ========================================================
-- MANGOPOS - ROLES BASE Y PERMISOS
-- Insertar roles predefinidos con sus permisos
-- ========================================================

-- NOTA: Este script debe ejecutarse DESPUÉS de roles_permissions_schema.sql
-- Reemplaza {business_id} con el ID real del negocio

-- ========================================================
-- FUNCIÓN HELPER PARA ASIGNAR PERMISOS A UN ROL
-- ========================================================

CREATE OR REPLACE FUNCTION assign_permissions_to_role(
  p_role_id uuid,
  p_permission_codes text[]
)
RETURNS void AS $$
DECLARE
  perm_code text;
  perm_id uuid;
BEGIN
  FOREACH perm_code IN ARRAY p_permission_codes
  LOOP
    SELECT id INTO perm_id FROM public.permissions WHERE code = perm_code;
    IF perm_id IS NOT NULL THEN
      INSERT INTO public.role_permissions (role_id, permission_id, allow)
      VALUES (p_role_id, perm_id, true)
      ON CONFLICT (role_id, permission_id) DO NOTHING;
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ========================================================
-- INSERTAR ROLES BASE
-- ========================================================

DO $$
DECLARE
  v_business_id uuid := '{business_id}'; -- REEMPLAZAR CON EL ID REAL
  v_admin_role_id uuid;
  v_supervisor_role_id uuid;
  v_cajero_role_id uuid;
  v_mesero_role_id uuid;
  v_cocina_role_id uuid;
  v_delivery_role_id uuid;
BEGIN

-- 1. ROL: ADMINISTRADOR
INSERT INTO public.roles (business_id, name, description, level, is_system)
VALUES (v_business_id, 'Administrador', 'Control total del sistema y configuración', 'admin', true)
RETURNING id INTO v_admin_role_id;

-- Asignar TODOS los permisos al Administrador
INSERT INTO public.role_permissions (role_id, permission_id, allow)
SELECT v_admin_role_id, id, true
FROM public.permissions;

-- 2. ROL: SUPERVISOR
INSERT INTO public.roles (business_id, name, description, level, is_system)
VALUES (v_business_id, 'Supervisor', 'Supervisión de ventas, puede anular y reimprimir', 'supervisor', true)
RETURNING id INTO v_supervisor_role_id;

PERFORM assign_permissions_to_role(v_supervisor_role_id, ARRAY[
  -- Ventas completas
  'ventas.mesas.acceso',
  'ventas.mesas.ver_estado',
  'ventas.mesas.abrir',
  'ventas.mesas.mover_unir',
  'ventas.mesas.marcar_pagando',
  'ventas.mesas.liberar',
  'ventas.orden.agregar_item',
  'ventas.orden.editar_item',
  'ventas.orden.eliminar_item',
  'ventas.orden.enviar_cocina',
  'ventas.orden.reabrir',
  'ventas.orden.anular',
  'ventas.orden.descuento_aplicar',
  'ventas.orden.ver_total',
  'ventas.cuenta.split_manual',
  'ventas.cuenta.split_equiv',
  -- Venta rápida
  'ventas_rapida.acceso',
  'ventas_rapida.crear_orden',
  'ventas_rapida.enviar_cocina',
  'ventas_rapida.cobrar_inmediato',
  -- Pagos completos
  'pagos.acceso',
  'pagos.cobrar_efectivo',
  'pagos.cobrar_tarjeta',
  'pagos.cobrar_transferencia',
  'pagos.asignar_referencia',
  'pagos.reimprimir_recibo',
  'pagos.anular_pago',
  -- Caja completa
  'caja.apertura',
  'caja.cierre',
  'caja.arqueo_ver',
  'caja.movimientos_ver',
  -- KDS
  'kds.acceso',
  'kds.ver_comandas',
  'kds.cambiar_estado',
  'kds.reimprimir_comanda',
  -- Reportes
  'reportes.ventas',
  'reportes.productos',
  'reportes.mesas',
  'reportes.caja',
  'reportes.fiscales',
  'reportes.auditoria',
  -- Clientes
  'clientes.ver',
  'clientes.crear_editar',
  'clientes.asignar_a_mesa'
]);

-- 3. ROL: CAJERO
INSERT INTO public.roles (business_id, name, description, level, is_system)
VALUES (v_business_id, 'Cajero', 'Cobros, caja y ventas rápidas', 'operador', true)
RETURNING id INTO v_cajero_role_id;

PERFORM assign_permissions_to_role(v_cajero_role_id, ARRAY[
  -- Ventas básicas
  'ventas.orden.agregar_item',
  'ventas.orden.enviar_cocina',
  'ventas.orden.ver_total',
  -- Venta rápida
  'ventas_rapida.acceso',
  'ventas_rapida.crear_orden',
  'ventas_rapida.enviar_cocina',
  'ventas_rapida.cobrar_inmediato',
  -- Pagos
  'pagos.acceso',
  'pagos.cobrar_efectivo',
  'pagos.cobrar_tarjeta',
  'pagos.cobrar_transferencia',
  'pagos.asignar_referencia',
  'pagos.reimprimir_recibo',
  -- Caja
  'caja.apertura',
  'caja.cierre',
  'caja.arqueo_ver',
  'caja.movimientos_ver',
  -- Clientes básico
  'clientes.ver'
]);

-- 4. ROL: MESERO
INSERT INTO public.roles (business_id, name, description, level, is_system)
VALUES (v_business_id, 'Mesero', 'Toma de pedidos, envía a cocina, split', 'operador', true)
RETURNING id INTO v_mesero_role_id;

PERFORM assign_permissions_to_role(v_mesero_role_id, ARRAY[
  -- Mesas
  'ventas.mesas.acceso',
  'ventas.mesas.ver_estado',
  'ventas.mesas.abrir',
  'ventas.mesas.mover_unir',
  'ventas.mesas.marcar_pagando',
  -- Órdenes
  'ventas.orden.agregar_item',
  'ventas.orden.editar_item',
  'ventas.orden.eliminar_item',
  'ventas.orden.enviar_cocina',
  'ventas.orden.ver_total',
  -- Split
  'ventas.cuenta.split_manual',
  'ventas.cuenta.split_equiv',
  -- Clientes
  'clientes.ver',
  'clientes.asignar_a_mesa'
]);

-- 5. ROL: COCINA/KDS
INSERT INTO public.roles (business_id, name, description, level, is_system)
VALUES (v_business_id, 'Cocina', 'Visualización y gestión de comandas en cocina', 'operador', true)
RETURNING id INTO v_cocina_role_id;

PERFORM assign_permissions_to_role(v_cocina_role_id, ARRAY[
  'kds.acceso',
  'kds.ver_comandas',
  'kds.cambiar_estado',
  'kds.reimprimir_comanda'
]);

-- 6. ROL: DELIVERY
INSERT INTO public.roles (business_id, name, description, level, is_system)
VALUES (v_business_id, 'Delivery', 'Gestión de entregas a domicilio', 'operador', true)
RETURNING id INTO v_delivery_role_id;

PERFORM assign_permissions_to_role(v_delivery_role_id, ARRAY[
  'delivery.crear_orden',
  'delivery.asignar_repartidor',
  'delivery.marcar_entregado',
  'clientes.ver',
  'ventas.orden.ver_total'
]);

END $$;

-- ========================================================
-- VERIFICACIÓN
-- ========================================================

-- Ver roles creados
SELECT 
  r.name,
  r.description,
  r.level,
  COUNT(rp.id) as permisos_count
FROM public.roles r
LEFT JOIN public.role_permissions rp ON rp.role_id = r.id
WHERE r.is_system = true
GROUP BY r.id, r.name, r.description, r.level
ORDER BY r.name;

-- Ver permisos por rol
SELECT 
  r.name as rol,
  p.module as modulo,
  COUNT(*) as cantidad_permisos
FROM public.roles r
JOIN public.role_permissions rp ON rp.role_id = r.id
JOIN public.permissions p ON p.id = rp.permission_id
WHERE r.is_system = true
GROUP BY r.name, p.module
ORDER BY r.name, p.module;
