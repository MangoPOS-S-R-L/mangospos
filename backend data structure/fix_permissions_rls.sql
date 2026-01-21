-- ================================================================
-- CORRECCIÓN FINAL DE RLS PARA GESTIÓN DE ROLES Y PERMISOS
-- Habilita permisos de escritura en 'permissions' y 'role_permissions'
-- ================================================================

-- 1. Desbloquear la tabla maestra de 'permissions' (si la app intenta crear nuevos permisos on-the-fly)
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can insert permissions" ON public.permissions;
CREATE POLICY "Users can insert permissions"
  ON public.permissions FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

-- Permitir lectura pública para todos los autenticados
DROP POLICY IF EXISTS "Users can view permissions" ON public.permissions;
CREATE POLICY "Users can view permissions"
  ON public.permissions FOR SELECT
  USING (auth.role() = 'authenticated');


-- 2. Desbloquear la tabla de asignaciones 'role_permissions' (CRÍTICO para guardar la configuración)
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can manage role_permissions" ON public.role_permissions;

CREATE POLICY "Users can manage role_permissions"
  ON public.role_permissions FOR ALL
  USING (
    role_id IN (
      SELECT id FROM public.roles WHERE business_id IN (
        SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
        UNION
        SELECT business_id FROM public.user_businesses WHERE user_id = auth.uid()
      )
    )
  );
