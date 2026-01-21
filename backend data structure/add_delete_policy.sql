-- Habilitar la eliminación de empleados para usuarios del mismo negocio
DROP POLICY IF EXISTS "Users can delete employees in their business" ON public.employees;

CREATE POLICY "Users can delete employees in their business"
  ON public.employees FOR DELETE
  USING (business_id IN (
    SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
  ));
