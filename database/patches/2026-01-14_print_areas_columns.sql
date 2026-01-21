-- Corrige la estructura de impresión para que coincida con el frontend.
-- Agrega columnas faltantes y actualiza la vista.

-- 1) print_areas: code + is_active + constraint de unicidad
ALTER TABLE public.print_areas
  ADD COLUMN IF NOT EXISTS code text;

ALTER TABLE public.print_areas
  ADD COLUMN IF NOT EXISTS is_active boolean DEFAULT true;

UPDATE public.print_areas
SET
  code = COALESCE(code, concat('area_', left(id::text, 8))),
  is_active = COALESCE(is_active, true);

ALTER TABLE public.print_areas
  ALTER COLUMN code SET NOT NULL,
  ALTER COLUMN is_active SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'print_areas_business_id_code_key'
      AND conrelid = 'public.print_areas'::regclass
  ) THEN
    ALTER TABLE public.print_areas
      ADD CONSTRAINT print_areas_business_id_code_key
      UNIQUE (business_id, code);
  END IF;
END$$;

-- 2) print_area_printers: priority requerido por el cliente Flutter
ALTER TABLE public.print_area_printers
  ADD COLUMN IF NOT EXISTS priority integer DEFAULT 1;

UPDATE public.print_area_printers
SET priority = COALESCE(priority, 1);

ALTER TABLE public.print_area_printers
  ALTER COLUMN priority SET NOT NULL;

-- Trigger para alinear business_id con el del área (evita inserts inválidos)
CREATE OR REPLACE FUNCTION public.trg_sync_pap_business()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- si no viene business_id, o viene distinto, se toma el de la print_area
  SELECT business_id INTO NEW.business_id FROM public.print_areas WHERE id = NEW.area_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_pap_business ON public.print_area_printers;
CREATE TRIGGER trg_sync_pap_business
BEFORE INSERT OR UPDATE ON public.print_area_printers
FOR EACH ROW EXECUTE FUNCTION public.trg_sync_pap_business();

-- 3) Vista con las columnas nuevas (drop + create para evitar renombrar columnas)
DROP VIEW IF EXISTS public.print_areas_view;

CREATE VIEW public.print_areas_view AS
SELECT
  id,
  business_id,
  name,
  code,
  is_active,
  created_at,
  0::int AS products_count
FROM public.print_areas a;

GRANT SELECT ON public.print_areas_view TO anon, authenticated, service_role;

-- 4) printers: columnas que usa el frontend (compatibilidad)
ALTER TABLE public.printers
  ADD COLUMN IF NOT EXISTS ip_address text,
  ADD COLUMN IF NOT EXISTS port integer,
  ADD COLUMN IF NOT EXISTS device_path text,
  ADD COLUMN IF NOT EXISTS is_active boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS paper_width integer DEFAULT 80,
  ADD COLUMN IF NOT EXISTS encoding text DEFAULT 'CP437';

UPDATE public.printers
SET
  ip_address = COALESCE(ip_address, ip::text),
  is_active = COALESCE(is_active, true),
  paper_width = COALESCE(paper_width, 80),
  encoding = COALESCE(encoding, 'CP437');

ALTER TABLE public.printers
  ALTER COLUMN is_active SET NOT NULL;

-- 5) RLS: permitir insertar/actualizar asignaciones si es admin del negocio
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'print_area_printers'
      AND policyname = 'insert area_printers admins'
  ) THEN
    CREATE POLICY "insert area_printers admins"
    ON public.print_area_printers
    FOR INSERT
    WITH CHECK (
      public.is_admin_of_business(
        COALESCE(
          business_id,
          (SELECT pa.business_id FROM public.print_areas pa WHERE pa.id = area_id)
        )
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'print_area_printers'
      AND policyname = 'update area_printers admins'
  ) THEN
    CREATE POLICY "update area_printers admins"
    ON public.print_area_printers
    FOR UPDATE
    USING (public.is_admin_of_business(business_id))
    WITH CHECK (public.is_admin_of_business(business_id));
  END IF;
END$$;
