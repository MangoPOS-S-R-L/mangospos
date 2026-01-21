-- ========================================================
-- MANGOPOS - ACTUALIZACIÓN DE SISTEMA DE ROLES Y PERMISOS
-- Este script actualiza las tablas existentes
-- ========================================================

-- ========================================================
-- PASO 1: AGREGAR COLUMNAS FALTANTES A EMPLOYEES
-- ========================================================

-- Agregar columnas que puedan faltar (si ya existen, no hará nada)
DO $$ 
BEGIN
    -- Agregar business_id si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='business_id') THEN
        ALTER TABLE public.employees ADD COLUMN business_id uuid;
        ALTER TABLE public.employees ADD CONSTRAINT employees_business_id_fkey 
            FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE CASCADE;
    END IF;

    -- Agregar hire_date si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='hire_date') THEN
        ALTER TABLE public.employees ADD COLUMN hire_date date;
    END IF;

    -- Agregar contract_type si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='contract_type') THEN
        ALTER TABLE public.employees ADD COLUMN contract_type text;
    END IF;

    -- Agregar department si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='department') THEN
        ALTER TABLE public.employees ADD COLUMN department text;
    END IF;

    -- Agregar position si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='position') THEN
        ALTER TABLE public.employees ADD COLUMN position text;
    END IF;

    -- Agregar work_schedule si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='work_schedule') THEN
        ALTER TABLE public.employees ADD COLUMN work_schedule text;
    END IF;

    -- Agregar salary_base si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='salary_base') THEN
        ALTER TABLE public.employees ADD COLUMN salary_base numeric(15,2);
    END IF;

    -- Agregar pay_frequency si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='pay_frequency') THEN
        ALTER TABLE public.employees ADD COLUMN pay_frequency text;
    END IF;

    -- Agregar bank_name si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='bank_name') THEN
        ALTER TABLE public.employees ADD COLUMN bank_name text;
    END IF;

    -- Agregar bank_account si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='bank_account') THEN
        ALTER TABLE public.employees ADD COLUMN bank_account text;
    END IF;

    -- Agregar emergency_name si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='emergency_name') THEN
        ALTER TABLE public.employees ADD COLUMN emergency_name text;
    END IF;

    -- Agregar emergency_relation si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='emergency_relation') THEN
        ALTER TABLE public.employees ADD COLUMN emergency_relation text;
    END IF;

    -- Agregar emergency_phone si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='employees' AND column_name='emergency_phone') THEN
        ALTER TABLE public.employees ADD COLUMN emergency_phone text;
    END IF;
END $$;

-- ========================================================
-- PASO 2: AGREGAR COLUMNAS FALTANTES A ROLES
-- ========================================================

DO $$ 
BEGIN
    -- Agregar business_id si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='roles' AND column_name='business_id') THEN
        ALTER TABLE public.roles ADD COLUMN business_id uuid;
        ALTER TABLE public.roles ADD CONSTRAINT roles_business_id_fkey 
            FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE CASCADE;
    END IF;

    -- Agregar level si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='roles' AND column_name='level') THEN
        ALTER TABLE public.roles ADD COLUMN level text;
    END IF;

    -- Agregar updated_at si no existe
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='roles' AND column_name='updated_at') THEN
        ALTER TABLE public.roles ADD COLUMN updated_at timestamptz DEFAULT now();
    END IF;
END $$;

-- ========================================================
-- PASO 3: CREAR TABLA EMPLOYEE_DEDUCTIONS SI NO EXISTE
-- ========================================================

CREATE TABLE IF NOT EXISTS public.employee_deductions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL,
  afp text,
  ars text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_deductions_pkey PRIMARY KEY (id),
  CONSTRAINT employee_deductions_employee_id_fkey FOREIGN KEY (employee_id) 
    REFERENCES public.employees(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_employee_deductions_employee_id ON public.employee_deductions(employee_id);

-- ========================================================
-- PASO 4: CREAR TABLA AUDIT_LOGS SI NO EXISTE
-- ========================================================

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL,
  employee_id uuid,
  action text NOT NULL,
  reason text,
  ref_id uuid,
  ref_type text,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT audit_logs_pkey PRIMARY KEY (id),
  CONSTRAINT audit_logs_business_id_fkey FOREIGN KEY (business_id) 
    REFERENCES public.businesses(id) ON DELETE CASCADE,
  CONSTRAINT audit_logs_employee_id_fkey FOREIGN KEY (employee_id) 
    REFERENCES public.employees(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_business_id ON public.audit_logs(business_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_employee_id ON public.audit_logs(employee_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON public.audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON public.audit_logs(created_at);

-- ========================================================
-- PASO 5: INSERTAR PERMISOS (si no existen)
-- ========================================================

INSERT INTO public.permissions (code, name, description, module) VALUES
-- CONFIGURACIÓN
('settings.usuarios.acceso', 'Acceso a Usuarios', 'Puede acceder al módulo de gestión de usuarios', 'configuracion'),
('settings.usuarios.ver', 'Ver Usuarios', 'Puede ver la lista de usuarios', 'configuracion'),
('settings.usuarios.crear', 'Crear Usuarios', 'Puede crear nuevos usuarios', 'configuracion'),
('settings.usuarios.editar', 'Editar Usuarios', 'Puede editar usuarios existentes', 'configuracion'),
('settings.usuarios.desactivar', 'Desactivar Usuarios', 'Puede desactivar usuarios', 'configuracion'),
('settings.roles.acceso', 'Acceso a Roles', 'Puede acceder a la gestión de roles', 'configuracion'),
('settings.roles.crear', 'Crear Roles', 'Puede crear nuevos roles', 'configuracion'),
('settings.roles.editar', 'Editar Roles', 'Puede editar roles existentes', 'configuracion'),
('settings.roles.clonar', 'Clonar Roles', 'Puede clonar roles', 'configuracion'),
('settings.roles.eliminar', 'Eliminar Roles', 'Puede eliminar roles', 'configuracion'),
('settings.impresoras.gestionar', 'Gestionar Impresoras', 'Puede configurar impresoras', 'configuracion'),
('settings.zonas_mesas.gestionar', 'Gestionar Zonas y Mesas', 'Puede configurar zonas y mesas', 'configuracion'),
('settings.impuestos_fiscal.gestionar', 'Gestionar Impuestos y Fiscal', 'Puede configurar ITBIS, NCF, etc', 'configuracion'),
('settings.metodos_pago.gestionar', 'Gestionar Métodos de Pago', 'Puede configurar métodos de pago', 'configuracion'),
('settings.descuentos_propinas.gestionar', 'Gestionar Descuentos y Propinas', 'Puede configurar descuentos y propinas', 'configuracion'),
('settings.kds.gestionar', 'Gestionar KDS', 'Puede configurar targets de impresión/KDS', 'configuracion'),
-- VENTAS POR SALÓN
('ventas.mesas.acceso', 'Acceso a Mesas', 'Puede acceder al módulo de ventas por salón', 'ventas'),
('ventas.mesas.ver_estado', 'Ver Estado de Mesas', 'Puede ver el estado de las mesas', 'ventas'),
('ventas.mesas.abrir', 'Abrir Mesas', 'Puede abrir mesas', 'ventas'),
('ventas.mesas.mover_unir', 'Mover/Unir Mesas', 'Puede mover y unir mesas', 'ventas'),
('ventas.mesas.marcar_pagando', 'Marcar Mesa Pagando', 'Puede marcar mesa como pagando', 'ventas'),
('ventas.mesas.liberar', 'Liberar Mesas', 'Puede liberar mesas cerradas', 'ventas'),
('ventas.orden.agregar_item', 'Agregar Items', 'Puede agregar items a órdenes', 'ventas'),
('ventas.orden.editar_item', 'Editar Items', 'Puede editar items de órdenes', 'ventas'),
('ventas.orden.eliminar_item', 'Eliminar Items', 'Puede eliminar items de órdenes', 'ventas'),
('ventas.orden.enviar_cocina', 'Enviar a Cocina', 'Puede enviar órdenes a cocina', 'ventas'),
('ventas.orden.reabrir', 'Reabrir Orden', 'Puede reabrir órdenes enviadas (requiere motivo)', 'ventas'),
('ventas.orden.anular', 'Anular Orden', 'Puede anular órdenes completas (requiere motivo)', 'ventas'),
('ventas.orden.descuento_aplicar', 'Aplicar Descuentos', 'Puede aplicar descuentos a órdenes', 'ventas'),
('ventas.orden.ver_total', 'Ver Total', 'Puede ver el total de órdenes', 'ventas'),
('ventas.cuenta.split_manual', 'Split Manual', 'Puede dividir cuenta manualmente', 'ventas'),
('ventas.cuenta.split_equiv', 'Split Equitativo', 'Puede dividir cuenta equitativamente', 'ventas'),
-- VENTA RÁPIDA
('ventas_rapida.acceso', 'Acceso a Venta Rápida', 'Puede acceder a venta rápida/express', 'ventas_rapida'),
('ventas_rapida.crear_orden', 'Crear Orden Rápida', 'Puede crear órdenes rápidas', 'ventas_rapida'),
('ventas_rapida.enviar_cocina', 'Enviar a Cocina', 'Puede enviar órdenes rápidas a cocina', 'ventas_rapida'),
('ventas_rapida.cobrar_inmediato', 'Cobrar Inmediato', 'Puede cobrar inmediatamente', 'ventas_rapida'),
-- PAGOS Y CAJA
('pagos.acceso', 'Acceso a Pagos', 'Puede acceder al módulo de pagos', 'pagos'),
('pagos.cobrar_efectivo', 'Cobrar en Efectivo', 'Puede procesar pagos en efectivo', 'pagos'),
('pagos.cobrar_tarjeta', 'Cobrar con Tarjeta', 'Puede procesar pagos con tarjeta', 'pagos'),
('pagos.cobrar_transferencia', 'Cobrar por Transferencia', 'Puede procesar pagos por transferencia', 'pagos'),
('pagos.asignar_referencia', 'Asignar Referencia', 'Puede asignar referencias a pagos', 'pagos'),
('pagos.reimprimir_recibo', 'Reimprimir Recibo', 'Puede reimprimir recibos', 'pagos'),
('pagos.anular_pago', 'Anular Pago', 'Puede anular pagos (requiere motivo)', 'pagos'),
('caja.apertura', 'Apertura de Caja', 'Puede abrir caja', 'caja'),
('caja.cierre', 'Cierre de Caja', 'Puede cerrar caja', 'caja'),
('caja.arqueo_ver', 'Ver Arqueo', 'Puede ver arqueo de caja', 'caja'),
('caja.movimientos_ver', 'Ver Movimientos', 'Puede ver movimientos de caja', 'caja'),
-- KDS / COCINA
('kds.acceso', 'Acceso a KDS', 'Puede acceder al sistema de cocina (KDS)', 'kds'),
('kds.ver_comandas', 'Ver Comandas', 'Puede ver comandas en KDS', 'kds'),
('kds.cambiar_estado', 'Cambiar Estado', 'Puede cambiar estado de comandas', 'kds'),
('kds.reimprimir_comanda', 'Reimprimir Comanda', 'Puede reimprimir comandas', 'kds'),
-- REPORTES
('reportes.ventas', 'Reportes de Ventas', 'Puede ver reportes de ventas', 'reportes'),
('reportes.productos', 'Reportes de Productos', 'Puede ver reportes de productos', 'reportes'),
('reportes.mesas', 'Reportes de Mesas', 'Puede ver reportes de mesas', 'reportes'),
('reportes.caja', 'Reportes de Caja', 'Puede ver reportes de caja', 'reportes'),
('reportes.fiscales', 'Reportes Fiscales', 'Puede ver reportes fiscales', 'reportes'),
('reportes.auditoria', 'Reportes de Auditoría', 'Puede ver reportes de auditoría', 'reportes'),
-- CLIENTES Y DELIVERY
('clientes.ver', 'Ver Clientes', 'Puede ver lista de clientes', 'clientes'),
('clientes.crear_editar', 'Crear/Editar Clientes', 'Puede crear y editar clientes', 'clientes'),
('clientes.asignar_a_mesa', 'Asignar a Mesa', 'Puede asignar clientes a mesas', 'clientes'),
('delivery.crear_orden', 'Crear Orden Delivery', 'Puede crear órdenes de delivery', 'delivery'),
('delivery.asignar_repartidor', 'Asignar Repartidor', 'Puede asignar repartidores', 'delivery'),
('delivery.marcar_entregado', 'Marcar Entregado', 'Puede marcar órdenes como entregadas', 'delivery'),
-- INVENTARIO Y COMPRAS
('inventario.acceso', 'Acceso a Inventario', 'Puede acceder al módulo de inventario', 'inventario'),
('inventario.productos.crear_editar', 'Crear/Editar Productos', 'Puede crear y editar productos', 'inventario'),
('inventario.ajustes.crear', 'Crear Ajustes', 'Puede crear ajustes de inventario', 'inventario'),
('inventario.kardex.ver', 'Ver Kardex', 'Puede ver kardex de inventario', 'inventario'),
('compras.proveedores.crear_editar', 'Crear/Editar Proveedores', 'Puede crear y editar proveedores', 'compras'),
('compras.ordenes.crear', 'Crear Órdenes de Compra', 'Puede crear órdenes de compra', 'compras'),
('compras.ordenes.recibir', 'Recibir Órdenes', 'Puede recibir órdenes de compra', 'compras'),
('compras.ordenes.anular', 'Anular Órdenes', 'Puede anular órdenes de compra', 'compras')
ON CONFLICT (code) DO NOTHING;

-- ========================================================
-- PASO 6: CREAR VISTA Y FUNCIÓN
-- ========================================================

DROP VIEW IF EXISTS public.v_employees_summary CASCADE;

CREATE OR REPLACE VIEW public.v_employees_summary AS
SELECT 
  e.id,
  e.business_id,
  e.first_name,
  e.last_name,
  e.email,
  e.phone,
  e.department,
  e.position,
  e.salary_base,
  e.pay_frequency,
  e.status,
  COALESCE(
    (SELECT json_agg(r.name)
     FROM public.employee_roles er
     JOIN public.roles r ON r.id = er.role_id
     WHERE er.employee_id = e.id),
    '[]'::json
  ) as roles
FROM public.employees e;

DROP FUNCTION IF EXISTS public.get_employee_permissions(uuid) CASCADE;

CREATE OR REPLACE FUNCTION public.get_employee_permissions(p_employee_id uuid)
RETURNS TABLE (permission_code text) AS $$
BEGIN
  RETURN QUERY
  SELECT DISTINCT p.code
  FROM public.permissions p
  WHERE p.id IN (
    SELECT rp.permission_id
    FROM public.employee_roles er
    JOIN public.role_permissions rp ON rp.role_id = er.role_id
    WHERE er.employee_id = p_employee_id AND rp.allow = true
    UNION
    SELECT upo.permission_id
    FROM public.user_permission_overrides upo
    WHERE upo.employee_id = p_employee_id AND upo.allow = true
  )
  AND p.id NOT IN (
    SELECT upo.permission_id
    FROM public.user_permission_overrides upo
    WHERE upo.employee_id = p_employee_id AND upo.allow = false
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ========================================================
-- PASO 7: CREAR ROLES BASE
-- ========================================================

DO $$
DECLARE
  v_business_id uuid := '4d068df7-a5bf-4f55-bea1-70a84d08d662';
  v_admin_role_id uuid;
  v_supervisor_role_id uuid;
  v_cajero_role_id uuid;
  v_mesero_role_id uuid;
  v_cocina_role_id uuid;
  v_delivery_role_id uuid;
BEGIN

-- Verificar si ya existen roles para este business
IF NOT EXISTS (SELECT 1 FROM public.roles WHERE business_id = v_business_id AND name = 'Administrador') THEN

  -- ROL: ADMINISTRADOR
  INSERT INTO public.roles (business_id, name, description, level, is_system)
  VALUES (v_business_id, 'Administrador', 'Control total del sistema y configuración', 'admin', true)
  RETURNING id INTO v_admin_role_id;

  INSERT INTO public.role_permissions (role_id, permission_id, allow)
  SELECT v_admin_role_id, id, true FROM public.permissions;

  -- ROL: SUPERVISOR
  INSERT INTO public.roles (business_id, name, description, level, is_system)
  VALUES (v_business_id, 'Supervisor', 'Supervisión de ventas, puede anular y reimprimir', 'supervisor', true)
  RETURNING id INTO v_supervisor_role_id;

  INSERT INTO public.role_permissions (role_id, permission_id, allow)
  SELECT v_supervisor_role_id, id, true FROM public.permissions
  WHERE code IN (
    'ventas.mesas.acceso','ventas.mesas.ver_estado','ventas.mesas.abrir','ventas.mesas.mover_unir',
    'ventas.mesas.marcar_pagando','ventas.mesas.liberar','ventas.orden.agregar_item','ventas.orden.editar_item',
    'ventas.orden.eliminar_item','ventas.orden.enviar_cocina','ventas.orden.reabrir','ventas.orden.anular',
    'ventas.orden.descuento_aplicar','ventas.orden.ver_total','ventas.cuenta.split_manual','ventas.cuenta.split_equiv',
    'ventas_rapida.acceso','ventas_rapida.crear_orden','ventas_rapida.enviar_cocina','ventas_rapida.cobrar_inmediato',
    'pagos.acceso','pagos.cobrar_efectivo','pagos.cobrar_tarjeta','pagos.cobrar_transferencia',
    'pagos.asignar_referencia','pagos.reimprimir_recibo','pagos.anular_pago',
    'caja.apertura','caja.cierre','caja.arqueo_ver','caja.movimientos_ver',
    'kds.acceso','kds.ver_comandas','kds.cambiar_estado','kds.reimprimir_comanda',
    'reportes.ventas','reportes.productos','reportes.mesas','reportes.caja','reportes.fiscales','reportes.auditoria',
    'clientes.ver','clientes.crear_editar','clientes.asignar_a_mesa'
  );

  -- ROL: CAJERO
  INSERT INTO public.roles (business_id, name, description, level, is_system)
  VALUES (v_business_id, 'Cajero', 'Cobros, caja y ventas rápidas', 'operador', true)
  RETURNING id INTO v_cajero_role_id;

  INSERT INTO public.role_permissions (role_id, permission_id, allow)
  SELECT v_cajero_role_id, id, true FROM public.permissions
  WHERE code IN (
    'ventas.orden.agregar_item','ventas.orden.enviar_cocina','ventas.orden.ver_total',
    'ventas_rapida.acceso','ventas_rapida.crear_orden','ventas_rapida.enviar_cocina','ventas_rapida.cobrar_inmediato',
    'pagos.acceso','pagos.cobrar_efectivo','pagos.cobrar_tarjeta','pagos.cobrar_transferencia',
    'pagos.asignar_referencia','pagos.reimprimir_recibo',
    'caja.apertura','caja.cierre','caja.arqueo_ver','caja.movimientos_ver',
    'clientes.ver'
  );

  -- ROL: MESERO
  INSERT INTO public.roles (business_id, name, description, level, is_system)
  VALUES (v_business_id, 'Mesero', 'Toma de pedidos, envía a cocina, split', 'operador', true)
  RETURNING id INTO v_mesero_role_id;

  INSERT INTO public.role_permissions (role_id, permission_id, allow)
  SELECT v_mesero_role_id, id, true FROM public.permissions
  WHERE code IN (
    'ventas.mesas.acceso','ventas.mesas.ver_estado','ventas.mesas.abrir','ventas.mesas.mover_unir','ventas.mesas.marcar_pagando',
    'ventas.orden.agregar_item','ventas.orden.editar_item','ventas.orden.eliminar_item','ventas.orden.enviar_cocina','ventas.orden.ver_total',
    'ventas.cuenta.split_manual','ventas.cuenta.split_equiv',
    'clientes.ver','clientes.asignar_a_mesa'
  );

  -- ROL: COCINA
  INSERT INTO public.roles (business_id, name, description, level, is_system)
  VALUES (v_business_id, 'Cocina', 'Visualización y gestión de comandas en cocina', 'operador', true)
  RETURNING id INTO v_cocina_role_id;

  INSERT INTO public.role_permissions (role_id, permission_id, allow)
  SELECT v_cocina_role_id, id, true FROM public.permissions
  WHERE code IN ('kds.acceso','kds.ver_comandas','kds.cambiar_estado','kds.reimprimir_comanda');

  -- ROL: DELIVERY
  INSERT INTO public.roles (business_id, name, description, level, is_system)
  VALUES (v_business_id, 'Delivery', 'Gestión de entregas a domicilio', 'operador', true)
  RETURNING id INTO v_delivery_role_id;

  INSERT INTO public.role_permissions (role_id, permission_id, allow)
  SELECT v_delivery_role_id, id, true FROM public.permissions
  WHERE code IN ('delivery.crear_orden','delivery.asignar_repartidor','delivery.marcar_entregado','clientes.ver','ventas.orden.ver_total');

END IF;

END $$;

-- ========================================================
-- PASO 8: VERIFICACIÓN
-- ========================================================

SELECT 'Roles creados:' as status;
SELECT 
  r.name as rol,
  r.description,
  r.level,
  COUNT(rp.id) as permisos_count
FROM public.roles r
LEFT JOIN public.role_permissions rp ON rp.role_id = r.id
WHERE r.is_system = true
GROUP BY r.id, r.name, r.description, r.level
ORDER BY r.name;

SELECT 'Permisos por módulo:' as status;
SELECT 
  module as modulo,
  COUNT(*) as total_permisos
FROM public.permissions
GROUP BY module
ORDER BY module;

-- ========================================================
-- ✅ ACTUALIZACIÓN COMPLETA
-- ========================================================
