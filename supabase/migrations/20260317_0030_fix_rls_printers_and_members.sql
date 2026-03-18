-- 20260317_0030_fix_rls_printers_and_members.sql
-- 1. Mejorar verificación de membresía y acceso a negocios para incluir la tabla employees
-- Esto soluciona los problemas de RLS para usuarios que no están en memberships/user_businesses antiguos.

CREATE OR REPLACE FUNCTION public.current_user_business_ids()
RETURNS TABLE(business_id uuid) LANGUAGE sql STABLE AS $$
  -- De memberships (owners antiguos)
  SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
  UNION
  -- De user_businesses (sistema anterior)
  SELECT business_id FROM public.user_businesses WHERE user_id = auth.uid()
  UNION
  -- De employees (sistema actual basado en empleados)
  SELECT business_id FROM public.employees WHERE user_id = auth.uid();
$$;

-- 2. Corregir funciones de verificación de roles para usar la nueva lógica de negocios
CREATE OR REPLACE FUNCTION public.is_member_of_business(p_business uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.current_user_business_ids() b
    WHERE b.business_id = p_business
  );
$$;

CREATE OR REPLACE FUNCTION public.is_admin_of_business(p_business uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.memberships m
    WHERE m.business_id = p_business AND m.user_id = auth.uid()
      AND m.role IN ('owner', 'admin')
  ) OR EXISTS(
    SELECT 1 FROM public.user_businesses ub
    WHERE ub.business_id = p_business AND ub.user_id = auth.uid()
      AND ub.role IN ('owner', 'admin')
  ) OR EXISTS(
    -- En el sistema de empleados, un admin/owner suele tener un rol con nivel 'admin'
    SELECT 1 FROM public.employees e
    JOIN public.employee_roles er ON er.employee_id = e.id
    JOIN public.roles r ON r.id = er.role_id
    WHERE e.business_id = p_business AND e.user_id = auth.uid()
      AND (r.level = 'admin' OR lower(r.name) IN ('administrador', 'propietario', 'owner', 'admin'))
  );
$$;

-- 3. Asegurar que las políticas de table_sessions permitan ver cualquier mesa del negocio
-- Esto corrige que las mesas ocupadas aparezcan como disponibles (session_id nulo) por RLS restrictivo.
DROP POLICY IF EXISTS "sessions_all" ON public.table_sessions;
CREATE POLICY "sessions_all" ON public.table_sessions
FOR SELECT TO authenticated
USING (business_id IN (SELECT current_user_business_ids()));

-- 4. Otorgar permisos de mesas a Cajeros por defecto
-- El usuario solicitó que los cajeros puedan abrir cualquier mesa por defecto.
DO $$
DECLARE
  v_perm_ids uuid[];
  v_cajero_role_id uuid;
BEGIN
  -- Obtener IDs de permisos de mesas
  SELECT array_agg(id) INTO v_perm_ids
  FROM public.permissions 
  WHERE code IN ('ventas.mesas.acceso', 'ventas.mesas.abrir', 'ventas.mesas.ver_estado');

  -- Actualizar para cada negocio que tenga un rol llamado 'Cajero' o 'Cashier'
  FOR v_cajero_role_id IN 
    SELECT id FROM public.roles WHERE lower(name) IN ('cajero', 'cashier')
  LOOP
    INSERT INTO public.role_permissions (role_id, permission_id, allow)
    SELECT v_cajero_role_id, p_id, true
    FROM unnest(v_perm_ids) AS p_id
    ON CONFLICT (role_id, permission_id) DO UPDATE SET allow = true;
  END LOOP;
END $$;
