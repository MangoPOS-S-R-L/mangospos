-- ========================================================
-- MANGOPOS - SISTEMA DE ROLES Y PERMISOS
-- Basado en roles_usuarios_mangopos.txt
-- ========================================================

-- 1. TABLA DE EMPLEADOS
CREATE TABLE IF NOT EXISTS public.employees (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL,
  user_id uuid REFERENCES auth.users(id),
  first_name text NOT NULL,
  last_name text NOT NULL,
  email text NOT NULL,
  phone text,
  national_id text,
  gender text,
  address text,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'password_reset')),
  hire_date date,
  contract_type text,
  department text,
  position text,
  work_schedule text,
  salary_base numeric(15,2),
  pay_frequency text,
  bank_name text,
  bank_account text,
  emergency_name text,
  emergency_relation text,
  emergency_phone text,
  pin text, -- hashed PIN for quick access
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT employees_pkey PRIMARY KEY (id),
  CONSTRAINT employees_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE CASCADE
);

-- Índices para employees
CREATE INDEX IF NOT EXISTS idx_employees_business_id ON public.employees(business_id);
CREATE INDEX IF NOT EXISTS idx_employees_email ON public.employees(email);
CREATE INDEX IF NOT EXISTS idx_employees_status ON public.employees(status);

-- 2. TABLA DE ROLES
CREATE TABLE IF NOT EXISTS public.roles (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL,
  name text NOT NULL,
  description text,
  level text, -- admin | supervisor | operador (opcional)
  is_system boolean NOT NULL DEFAULT false, -- true para roles predefinidos
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT roles_pkey PRIMARY KEY (id),
  CONSTRAINT roles_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE CASCADE,
  CONSTRAINT roles_unique_name_per_business UNIQUE (business_id, name)
);

CREATE INDEX IF NOT EXISTS idx_roles_business_id ON public.roles(business_id);

-- 3. TABLA DE PERMISOS
CREATE TABLE IF NOT EXISTS public.permissions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE, -- ej: 'ventas.mesas.acceso'
  name text NOT NULL,
  description text,
  module text NOT NULL, -- configuracion | ventas | pagos | kds | reportes | etc
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT permissions_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_permissions_code ON public.permissions(code);
CREATE INDEX IF NOT EXISTS idx_permissions_module ON public.permissions(module);

-- 4. TABLA DE PERMISOS POR ROL
CREATE TABLE IF NOT EXISTS public.role_permissions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  role_id uuid NOT NULL,
  permission_id uuid NOT NULL,
  allow boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT role_permissions_pkey PRIMARY KEY (id),
  CONSTRAINT role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE,
  CONSTRAINT role_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES public.permissions(id) ON DELETE CASCADE,
  CONSTRAINT role_permissions_unique UNIQUE (role_id, permission_id)
);

CREATE INDEX IF NOT EXISTS idx_role_permissions_role_id ON public.role_permissions(role_id);

-- 5. TABLA DE ROLES POR EMPLEADO (permite multi-rol)
CREATE TABLE IF NOT EXISTS public.employee_roles (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL,
  role_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_roles_pkey PRIMARY KEY (id),
  CONSTRAINT employee_roles_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT employee_roles_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE,
  CONSTRAINT employee_roles_unique UNIQUE (employee_id, role_id)
);

CREATE INDEX IF NOT EXISTS idx_employee_roles_employee_id ON public.employee_roles(employee_id);
CREATE INDEX IF NOT EXISTS idx_employee_roles_role_id ON public.employee_roles(role_id);

-- 6. TABLA DE EXCEPCIONES DE PERMISOS POR USUARIO (opcional)
CREATE TABLE IF NOT EXISTS public.user_permission_overrides (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL,
  permission_id uuid NOT NULL,
  allow boolean NOT NULL,
  reason text,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_permission_overrides_pkey PRIMARY KEY (id),
  CONSTRAINT user_permission_overrides_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT user_permission_overrides_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES public.permissions(id) ON DELETE CASCADE,
  CONSTRAINT user_permission_overrides_unique UNIQUE (employee_id, permission_id)
);

CREATE INDEX IF NOT EXISTS idx_user_permission_overrides_employee_id ON public.user_permission_overrides(employee_id);

-- 7. TABLA DE BENEFICIOS DE EMPLEADOS
CREATE TABLE IF NOT EXISTS public.employee_benefits (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL,
  benefit text NOT NULL, -- Transporte | Alimentación | etc
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_benefits_pkey PRIMARY KEY (id),
  CONSTRAINT employee_benefits_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_employee_benefits_employee_id ON public.employee_benefits(employee_id);

-- 8. TABLA DE DEDUCCIONES DE EMPLEADOS
CREATE TABLE IF NOT EXISTS public.employee_deductions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL,
  afp text,
  ars text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_deductions_pkey PRIMARY KEY (id),
  CONSTRAINT employee_deductions_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_employee_deductions_employee_id ON public.employee_deductions(employee_id);

-- 9. TABLA DE AUDITORÍA
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL,
  employee_id uuid,
  action text NOT NULL, -- anular_venta | reimprimir | reabrir_orden | etc
  reason text,
  ref_id uuid,
  ref_type text, -- order | payment | fiscal_document | etc
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT audit_logs_pkey PRIMARY KEY (id),
  CONSTRAINT audit_logs_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE CASCADE,
  CONSTRAINT audit_logs_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_business_id ON public.audit_logs(business_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_employee_id ON public.audit_logs(employee_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON public.audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON public.audit_logs(created_at);

-- ========================================================
-- INSERTAR PERMISOS BASE
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
-- VISTA PARA RESUMEN DE EMPLEADOS CON ROLES
-- ========================================================

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

-- ========================================================
-- FUNCIÓN PARA OBTENER PERMISOS DE UN EMPLEADO
-- ========================================================

CREATE OR REPLACE FUNCTION public.get_employee_permissions(p_employee_id uuid)
RETURNS TABLE (permission_code text) AS $$
BEGIN
  RETURN QUERY
  SELECT DISTINCT p.code
  FROM public.permissions p
  WHERE p.id IN (
    -- Permisos desde roles
    SELECT rp.permission_id
    FROM public.employee_roles er
    JOIN public.role_permissions rp ON rp.role_id = er.role_id
    WHERE er.employee_id = p_employee_id
      AND rp.allow = true
    
    UNION
    
    -- Permisos desde overrides
    SELECT upo.permission_id
    FROM public.user_permission_overrides upo
    WHERE upo.employee_id = p_employee_id
      AND upo.allow = true
  )
  AND p.id NOT IN (
    -- Excluir permisos denegados por overrides
    SELECT upo.permission_id
    FROM public.user_permission_overrides upo
    WHERE upo.employee_id = p_employee_id
      AND upo.allow = false
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ========================================================
-- RLS (Row Level Security)
-- ========================================================

-- Habilitar RLS en todas las tablas
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_permission_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_benefits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_deductions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para employees
CREATE POLICY "Users can view employees in their business"
  ON public.employees FOR SELECT
  USING (business_id IN (
    SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
  ));

CREATE POLICY "Users can insert employees in their business"
  ON public.employees FOR INSERT
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
  ));

CREATE POLICY "Users can update employees in their business"
  ON public.employees FOR UPDATE
  USING (business_id IN (
    SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
  ));

-- Políticas para roles
CREATE POLICY "Users can view roles in their business"
  ON public.roles FOR SELECT
  USING (business_id IN (
    SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
  ));

CREATE POLICY "Users can manage roles in their business"
  ON public.roles FOR ALL
  USING (business_id IN (
    SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
  ));

-- Políticas para employee_roles
CREATE POLICY "Users can view employee roles in their business"
  ON public.employee_roles FOR SELECT
  USING (employee_id IN (
    SELECT id FROM public.employees WHERE business_id IN (
      SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
    )
  ));

CREATE POLICY "Users can manage employee roles in their business"
  ON public.employee_roles FOR ALL
  USING (employee_id IN (
    SELECT id FROM public.employees WHERE business_id IN (
      SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
    )
  ));

-- Políticas para audit_logs
CREATE POLICY "Users can view audit logs in their business"
  ON public.audit_logs FOR SELECT
  USING (business_id IN (
    SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
  ));

CREATE POLICY "Users can insert audit logs in their business"
  ON public.audit_logs FOR INSERT
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
  ));

-- ========================================================
-- COMENTARIOS
-- ========================================================

COMMENT ON TABLE public.employees IS 'Empleados del negocio con información personal y laboral';
COMMENT ON TABLE public.roles IS 'Roles configurables para el sistema de permisos';
COMMENT ON TABLE public.permissions IS 'Catálogo de permisos del sistema';
COMMENT ON TABLE public.role_permissions IS 'Permisos asignados a cada rol';
COMMENT ON TABLE public.employee_roles IS 'Roles asignados a cada empleado (multi-rol)';
COMMENT ON TABLE public.user_permission_overrides IS 'Excepciones de permisos por usuario';
COMMENT ON TABLE public.audit_logs IS 'Registro de auditoría de acciones críticas';
