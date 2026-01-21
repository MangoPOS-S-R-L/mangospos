-- ================================================================
-- GARANTÍA DE ESTRUCTURA DE BASE DE DATOS
-- Ejecuta este script para asegurar que todas las tablas y columnas existen.
-- No borrará datos existentes.
-- ================================================================

-- 1. Asegurar que la tabla employees tenga todas las columnas nuevas
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS national_id text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS gender text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS address text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS hire_date date;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS contract_type text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS department text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS position text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS work_schedule text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS salary_base numeric(15,2);
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS pay_frequency text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS bank_name text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS bank_account text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS emergency_name text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS emergency_relation text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS emergency_phone text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS pin text;

-- 2. Asegurar que exista la tabla de Roles
CREATE TABLE IF NOT EXISTS public.roles (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL,
  name text NOT NULL,
  description text,
  level text,
  is_system boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT roles_pkey PRIMARY KEY (id),
  CONSTRAINT roles_unique_name_per_business UNIQUE (business_id, name)
);

-- 3. Asegurar que exista la tabla intermedia de Roles por Empleado
-- AQUÍ ES DONDE SE GUARDAN LOS ROLES REALMENTE
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

-- 4. Habilitar seguridad (RLS) en la tabla intermedia si no lo está
ALTER TABLE public.employee_roles ENABLE ROW LEVEL SECURITY;

-- 5. Crear política para permitir gestionar roles de empleados
DROP POLICY IF EXISTS "Users can manage employee roles in their business" ON public.employee_roles;

CREATE POLICY "Users can manage employee roles in their business"
  ON public.employee_roles FOR ALL
  USING (
    employee_id IN (
      SELECT id FROM public.employees WHERE business_id IN (
        SELECT business_id FROM public.memberships WHERE user_id = auth.uid()
        UNION
        SELECT business_id FROM public.user_businesses WHERE user_id = auth.uid()
      )
    )
  );

-- 6. Asegurar que la vista v_employees_summary exista y traiga los roles
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
