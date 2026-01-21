-- Eliminar la vista existente para evitar conflictos de columnas
DROP VIEW IF EXISTS public.v_employees_summary;

-- Volver a crear la vista con la estructura actualizada
CREATE OR REPLACE VIEW public.v_employees_summary AS
SELECT 
  e.*,
  COALESCE(
    (SELECT json_agg(r.name)
     FROM public.employee_roles er
     JOIN public.roles r ON r.id = er.role_id
     WHERE er.employee_id = e.id),
    '[]'::json
  ) as roles
FROM public.employees e;
