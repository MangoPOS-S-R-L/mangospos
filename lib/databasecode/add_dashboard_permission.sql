-- =============================================================================
-- Migración: dashboard.acceso + ajuste de permisos de cajero
--
-- Ejecutar en Supabase SQL Editor.
-- Seguro para re-ejecución (idempotente).
--
-- Cambios:
--   1. Agrega permiso 'dashboard.acceso' al catálogo
--   2. Actualiza fn_seed_business_rbac_defaults con la nueva matriz
--      - Cajero pierde: caja.arqueo_ver, reportes.caja, reportes.ventas
--      - Owner/Admin/Manager ganan: dashboard.acceso
--   3. Re-seedea TODOS los negocios existentes para aplicar los cambios
-- =============================================================================

-- 1. Insertar el permiso en el catálogo
INSERT INTO public.permissions (code, name, module, description)
VALUES (
  'dashboard.acceso',
  'Acceso al dashboard',
  'reports',
  'Abre el dashboard general con métricas, gráficos y resumen del negocio.'
)
ON CONFLICT (code) DO UPDATE
SET name        = excluded.name,
    module      = excluded.module,
    description = excluded.description;

-- 2. Actualizar la función de seed con la nueva matriz de permisos
CREATE OR REPLACE FUNCTION public.fn_seed_business_rbac_defaults(p_business_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_business_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.roles (business_id, name, description, is_system)
  SELECT p_business_id, seed.name, seed.description, true
  FROM (
    VALUES
      ('owner', 'Propietario del negocio'),
      ('admin', 'Administrador del negocio'),
      ('manager', 'Supervisor / gerente de turno'),
      ('cashier', 'Cajero'),
      ('waiter', 'Mesero'),
      ('cook', 'Cocina'),
      ('delivery', 'Delivery')
  ) AS seed(name, description)
  WHERE NOT EXISTS (
    SELECT 1 FROM public.roles r
    WHERE r.business_id = p_business_id AND lower(r.name) = seed.name
  );

  -- Limpiar permisos de roles de sistema para re-seedear
  DELETE FROM public.role_permissions rp
  USING public.roles r
  WHERE r.id = rp.role_id
    AND r.business_id = p_business_id
    AND r.is_system = true
    AND lower(r.name) IN ('owner','admin','manager','cashier','waiter','cook','delivery');

  INSERT INTO public.role_permissions (role_id, permission_id, allow)
  SELECT r.id, p.id, true
  FROM public.roles r
  JOIN (
    VALUES
      -- ===== OWNER =====
      ('owner','dashboard.acceso'),
      ('owner','ventas.mesas.acceso'),
      ('owner','ventas.mesas.ver_estado'),
      ('owner','ventas.mesas.abrir'),
      ('owner','ventas.mesas.mover_unir'),
      ('owner','ventas.mesas.marcar_pagando'),
      ('owner','ventas.mesas.liberar'),
      ('owner','ventas.orden.ver_total'),
      ('owner','ventas.orden.agregar_item'),
      ('owner','ventas.orden.editar_item'),
      ('owner','ventas.orden.eliminar_item'),
      ('owner','ventas.orden.enviar_cocina'),
      ('owner','ventas.orden.descuento_aplicar'),
      ('owner','ventas.orden.anular'),
      ('owner','ventas.orden.reabrir'),
      ('owner','ventas.cuenta.split_manual'),
      ('owner','ventas.cuenta.split_equiv'),
      ('owner','ventas_rapida.acceso'),
      ('owner','ventas_rapida.crear_orden'),
      ('owner','ventas_rapida.enviar_cocina'),
      ('owner','ventas_rapida.cobrar_inmediato'),
      ('owner','pagos.acceso'),
      ('owner','pagos.cobrar_efectivo'),
      ('owner','pagos.cobrar_tarjeta'),
      ('owner','pagos.cobrar_transferencia'),
      ('owner','pagos.asignar_referencia'),
      ('owner','pagos.anular_pago'),
      ('owner','pagos.reimprimir_recibo'),
      ('owner','caja.apertura'),
      ('owner','caja.cierre'),
      ('owner','caja.movimientos_ver'),
      ('owner','caja.arqueo_ver'),
      ('owner','kds.acceso'),
      ('owner','kds.ver_comandas'),
      ('owner','kds.cambiar_estado'),
      ('owner','kds.reimprimir_comanda'),
      ('owner','clientes.ver'),
      ('owner','clientes.crear_editar'),
      ('owner','clientes.asignar_a_mesa'),
      ('owner','delivery.crear_orden'),
      ('owner','delivery.asignar_repartidor'),
      ('owner','delivery.marcar_entregado'),
      ('owner','inventario.acceso'),
      ('owner','inventario.productos.crear_editar'),
      ('owner','inventario.ajustes.crear'),
      ('owner','compras.proveedores.crear_editar'),
      ('owner','compras.ordenes.crear'),
      ('owner','compras.ordenes.recibir'),
      ('owner','compras.ordenes.anular'),
      ('owner','reportes.ventas'),
      ('owner','reportes.productos'),
      ('owner','reportes.caja'),
      ('owner','reportes.fiscales'),
      ('owner','settings.usuarios.acceso'),
      ('owner','settings.usuarios.ver'),
      ('owner','settings.usuarios.crear'),
      ('owner','settings.usuarios.editar'),
      ('owner','settings.usuarios.desactivar'),
      ('owner','settings.roles.acceso'),
      ('owner','settings.roles.ver'),
      ('owner','settings.roles.crear'),
      ('owner','settings.roles.editar'),
      ('owner','settings.roles.eliminar'),
      ('owner','settings.impresoras.gestionar'),
      ('owner','settings.zonas_mesas.gestionar'),
      ('owner','settings.impuestos_fiscal.gestionar'),
      ('owner','settings.metodos_pago.gestionar'),
      ('owner','settings.descuentos_propinas.gestionar'),
      ('owner','settings.kds.gestionar'),

      -- ===== ADMIN =====
      ('admin','dashboard.acceso'),
      ('admin','ventas.mesas.acceso'),
      ('admin','ventas.mesas.ver_estado'),
      ('admin','ventas.mesas.abrir'),
      ('admin','ventas.mesas.mover_unir'),
      ('admin','ventas.mesas.marcar_pagando'),
      ('admin','ventas.mesas.liberar'),
      ('admin','ventas.orden.ver_total'),
      ('admin','ventas.orden.agregar_item'),
      ('admin','ventas.orden.editar_item'),
      ('admin','ventas.orden.eliminar_item'),
      ('admin','ventas.orden.enviar_cocina'),
      ('admin','ventas.orden.descuento_aplicar'),
      ('admin','ventas.orden.anular'),
      ('admin','ventas.orden.reabrir'),
      ('admin','ventas.cuenta.split_manual'),
      ('admin','ventas.cuenta.split_equiv'),
      ('admin','ventas_rapida.acceso'),
      ('admin','ventas_rapida.crear_orden'),
      ('admin','ventas_rapida.enviar_cocina'),
      ('admin','ventas_rapida.cobrar_inmediato'),
      ('admin','pagos.acceso'),
      ('admin','pagos.cobrar_efectivo'),
      ('admin','pagos.cobrar_tarjeta'),
      ('admin','pagos.cobrar_transferencia'),
      ('admin','pagos.asignar_referencia'),
      ('admin','pagos.anular_pago'),
      ('admin','pagos.reimprimir_recibo'),
      ('admin','caja.apertura'),
      ('admin','caja.cierre'),
      ('admin','caja.movimientos_ver'),
      ('admin','caja.arqueo_ver'),
      ('admin','kds.acceso'),
      ('admin','kds.ver_comandas'),
      ('admin','kds.cambiar_estado'),
      ('admin','kds.reimprimir_comanda'),
      ('admin','clientes.ver'),
      ('admin','clientes.crear_editar'),
      ('admin','clientes.asignar_a_mesa'),
      ('admin','delivery.crear_orden'),
      ('admin','delivery.asignar_repartidor'),
      ('admin','delivery.marcar_entregado'),
      ('admin','inventario.acceso'),
      ('admin','inventario.productos.crear_editar'),
      ('admin','inventario.ajustes.crear'),
      ('admin','compras.proveedores.crear_editar'),
      ('admin','compras.ordenes.crear'),
      ('admin','compras.ordenes.recibir'),
      ('admin','compras.ordenes.anular'),
      ('admin','reportes.ventas'),
      ('admin','reportes.productos'),
      ('admin','reportes.caja'),
      ('admin','reportes.fiscales'),
      ('admin','settings.usuarios.acceso'),
      ('admin','settings.usuarios.ver'),
      ('admin','settings.usuarios.crear'),
      ('admin','settings.usuarios.editar'),
      ('admin','settings.usuarios.desactivar'),
      ('admin','settings.roles.acceso'),
      ('admin','settings.roles.ver'),
      ('admin','settings.roles.crear'),
      ('admin','settings.roles.editar'),
      ('admin','settings.roles.eliminar'),
      ('admin','settings.impresoras.gestionar'),
      ('admin','settings.zonas_mesas.gestionar'),
      ('admin','settings.impuestos_fiscal.gestionar'),
      ('admin','settings.metodos_pago.gestionar'),
      ('admin','settings.descuentos_propinas.gestionar'),
      ('admin','settings.kds.gestionar'),

      -- ===== MANAGER =====
      ('manager','dashboard.acceso'),
      ('manager','ventas.mesas.acceso'),
      ('manager','ventas.mesas.ver_estado'),
      ('manager','ventas.mesas.abrir'),
      ('manager','ventas.mesas.mover_unir'),
      ('manager','ventas.mesas.marcar_pagando'),
      ('manager','ventas.mesas.liberar'),
      ('manager','ventas.orden.ver_total'),
      ('manager','ventas.orden.agregar_item'),
      ('manager','ventas.orden.editar_item'),
      ('manager','ventas.orden.eliminar_item'),
      ('manager','ventas.orden.enviar_cocina'),
      ('manager','ventas.orden.descuento_aplicar'),
      ('manager','ventas.orden.anular'),
      ('manager','ventas.orden.reabrir'),
      ('manager','ventas.cuenta.split_manual'),
      ('manager','ventas.cuenta.split_equiv'),
      ('manager','ventas_rapida.acceso'),
      ('manager','ventas_rapida.crear_orden'),
      ('manager','ventas_rapida.enviar_cocina'),
      ('manager','ventas_rapida.cobrar_inmediato'),
      ('manager','pagos.acceso'),
      ('manager','pagos.cobrar_efectivo'),
      ('manager','pagos.cobrar_tarjeta'),
      ('manager','pagos.cobrar_transferencia'),
      ('manager','pagos.asignar_referencia'),
      ('manager','pagos.anular_pago'),
      ('manager','pagos.reimprimir_recibo'),
      ('manager','caja.apertura'),
      ('manager','caja.cierre'),
      ('manager','caja.movimientos_ver'),
      ('manager','caja.arqueo_ver'),
      ('manager','kds.acceso'),
      ('manager','kds.ver_comandas'),
      ('manager','kds.cambiar_estado'),
      ('manager','kds.reimprimir_comanda'),
      ('manager','clientes.ver'),
      ('manager','clientes.crear_editar'),
      ('manager','clientes.asignar_a_mesa'),
      ('manager','delivery.crear_orden'),
      ('manager','delivery.asignar_repartidor'),
      ('manager','delivery.marcar_entregado'),
      ('manager','inventario.acceso'),
      ('manager','inventario.productos.crear_editar'),
      ('manager','inventario.ajustes.crear'),
      ('manager','compras.proveedores.crear_editar'),
      ('manager','compras.ordenes.crear'),
      ('manager','compras.ordenes.recibir'),
      ('manager','compras.ordenes.anular'),
      ('manager','reportes.ventas'),
      ('manager','reportes.productos'),
      ('manager','reportes.caja'),
      ('manager','reportes.fiscales'),
      ('manager','settings.usuarios.acceso'),
      ('manager','settings.usuarios.ver'),
      ('manager','settings.impresoras.gestionar'),
      ('manager','settings.zonas_mesas.gestionar'),
      ('manager','settings.descuentos_propinas.gestionar'),
      ('manager','settings.kds.gestionar'),

      -- ===== CASHIER =====
      -- Solo: abrir/cerrar caja, cobrar, registrar movimientos.
      -- SIN caja.arqueo_ver -> no ve totales, historial ni cierres.
      -- SIN reportes.* -> no accede a reportes.
      -- Cierre siempre "a ciegas" (blind close).
      ('cashier','ventas.mesas.acceso'),
      ('cashier','ventas.mesas.ver_estado'),
      ('cashier','ventas.orden.ver_total'),
      ('cashier','ventas_rapida.acceso'),
      ('cashier','ventas_rapida.crear_orden'),
      ('cashier','ventas_rapida.cobrar_inmediato'),
      ('cashier','pagos.acceso'),
      ('cashier','pagos.cobrar_efectivo'),
      ('cashier','pagos.cobrar_tarjeta'),
      ('cashier','pagos.cobrar_transferencia'),
      ('cashier','pagos.asignar_referencia'),
      ('cashier','pagos.reimprimir_recibo'),
      ('cashier','caja.apertura'),
      ('cashier','caja.cierre'),
      ('cashier','caja.movimientos_ver'),
      ('cashier','clientes.ver'),

      -- ===== WAITER =====
      ('waiter','ventas.mesas.acceso'),
      ('waiter','ventas.mesas.ver_estado'),
      ('waiter','ventas.mesas.abrir'),
      ('waiter','ventas.mesas.marcar_pagando'),
      ('waiter','ventas.orden.ver_total'),
      ('waiter','ventas.orden.agregar_item'),
      ('waiter','ventas.orden.editar_item'),
      ('waiter','ventas.orden.eliminar_item'),
      ('waiter','ventas.orden.enviar_cocina'),
      ('waiter','ventas.cuenta.split_manual'),
      ('waiter','ventas.cuenta.split_equiv'),
      ('waiter','clientes.ver'),
      ('waiter','clientes.asignar_a_mesa'),

      -- ===== COOK =====
      ('cook','kds.acceso'),
      ('cook','kds.ver_comandas'),
      ('cook','kds.cambiar_estado'),
      ('cook','kds.reimprimir_comanda'),

      -- ===== DELIVERY =====
      ('delivery','delivery.crear_orden'),
      ('delivery','delivery.asignar_repartidor'),
      ('delivery','delivery.marcar_entregado'),
      ('delivery','clientes.ver'),
      ('delivery','ventas_rapida.acceso'),
      ('delivery','ventas_rapida.crear_orden'),
      ('delivery','ventas.orden.ver_total')
  ) AS matrix(role_name, permission_code)
    ON matrix.role_name = lower(r.name)
  JOIN public.permissions p ON p.code = matrix.permission_code
  WHERE r.business_id = p_business_id
    AND r.is_system = true;

  INSERT INTO public.user_roles (user_id, role_id, business_id, created_by)
  SELECT ub.user_id, r.id, ub.business_id, auth.uid()
  FROM public.user_businesses ub
  JOIN public.roles r
    ON r.business_id = ub.business_id
   AND r.is_system = true
   AND lower(r.name) = (
     CASE
       WHEN ub.role IN ('owner','admin','manager','cashier','waiter','delivery') THEN ub.role
       WHEN ub.role IN ('cook','chef') THEN 'cook'
       ELSE 'waiter'
     END
   )
  WHERE ub.business_id = p_business_id
  ON CONFLICT DO NOTHING;
END;
$$;

-- 3. RE-SEEDEAR todos los negocios existentes para aplicar los cambios
--    Esto borra los role_permissions de sistema y los recrea con la nueva matriz.
--    Los user_permission_overrides NO se tocan (personalizaciones se preservan).
DO $$
DECLARE
  biz RECORD;
BEGIN
  FOR biz IN SELECT id FROM public.businesses LOOP
    PERFORM public.fn_seed_business_rbac_defaults(biz.id);
  END LOOP;
END;
$$;
