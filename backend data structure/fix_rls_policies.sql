-- ================================================================
-- CORRECCIÓN DE POLÍTICAS DE SEGURIDAD (RLS)
-- Permite gestionar empleados si el usuario pertenece al negocio
-- ya sea por 'memberships' o por 'user_businesses'
-- ================================================================

-- 1. Eliminar políticas antiguas para evitar conflictos
DROP POLICY IF EXISTS "Users can view employees in their business" ON public.employees;
DROP POLICY IF EXISTS "Users can insert employees in their business" ON public.employees;
DROP POLICY IF EXISTS "Users can update employees in their business" ON public.employees;
DROP POLICY IF EXISTS "Users can delete employees in their business" ON public.employees;

-- 2. Crear políticas unificadas y robustas

-- SELECT: Ver empleados
CREATE POLICY "Users can view employees in their business"
  ON public.employees FOR SELECT
  USING (
    business_id IN (
      SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
      UNION
      SELECT business_id FROM public.user_businesses WHERE user_id = auth.uid()
    )
  );

-- INSERT: Crear empleados
CREATE POLICY "Users can insert employees in their business"
  ON public.employees FOR INSERT
  WITH CHECK (
    business_id IN (
      SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
      UNION
      SELECT business_id FROM public.user_businesses WHERE user_id = auth.uid()
    )
  );

-- UPDATE: Editar empleados
CREATE POLICY "Users can update employees in their business"
  ON public.employees FOR UPDATE
  USING (
    business_id IN (
      SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
      UNION
      SELECT business_id FROM public.user_businesses WHERE user_id = auth.uid()
    )
  );

-- DELETE: Eliminar empleados
CREATE POLICY "Users can delete employees in their business"
  ON public.employees FOR DELETE
  USING (
    business_id IN (
      SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
      UNION
      SELECT business_id FROM public.user_businesses WHERE user_id = auth.uid()
    )
  );

-- ================================================================
-- Aplicar lógica similar para la tabla de roles para evitar bloqueos futuros
-- ================================================================

DROP POLICY IF EXISTS "Users can manage roles in their business" ON public.roles;

CREATE POLICY "Users can manage roles in their business"
  ON public.roles FOR ALL
  USING (
    business_id IN (
      SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
      UNION
      SELECT business_id FROM public.user_businesses WHERE user_id = auth.uid()
    )
  );
