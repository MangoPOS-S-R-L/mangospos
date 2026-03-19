-- 20260318_0033_fix_fiscal_policies.sql
-- Corregir RLS para permitir a administradores gestionar comprobantes y ajustes fiscales

-- 1. Secuencias NCF
DROP POLICY IF EXISTS "Acceso por negocio para secuencias_ncf" ON public.secuencias_ncf;
CREATE POLICY "Gestión de secuencias por negocio" ON public.secuencias_ncf
    FOR ALL USING (public.is_admin_of_business(business_id));

-- 2. Comprobantes
DROP POLICY IF EXISTS "Acceso por negocio para comprobantes" ON public.comprobantes;
CREATE POLICY "Gestión de comprobantes por negocio" ON public.comprobantes
    FOR ALL USING (public.is_admin_of_business(business_id));

-- 3. Negocios (para guardar RNC, Nombre Fiscal y preferencia e-CF)
DROP POLICY IF EXISTS "Update fiscal info on businesses" ON public.businesses;
CREATE POLICY "Update fiscal info on businesses" 
    ON public.businesses
    FOR UPDATE 
    TO authenticated
    USING (public.is_admin_of_business(id))
    WITH CHECK (public.is_admin_of_business(id));

-- 4. Otros ajustes fiscales (dgii_receipt_types, etc.) si existieran
ALTER TABLE IF EXISTS public.dgii_receipt_types ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Lectura de tipos para todos" ON public.dgii_receipt_types;
CREATE POLICY "Lectura de tipos para todos" ON public.dgii_receipt_types FOR SELECT TO authenticated USING (true);
