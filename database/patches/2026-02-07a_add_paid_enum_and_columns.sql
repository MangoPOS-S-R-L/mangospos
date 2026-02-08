-- Paso 1: agregar valor de estado 'paid' y columna de cierre
-- Ejecutar este archivo ANTES de cualquier uso del valor 'paid'
-- Fecha: 2026-02-07

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_enum e ON t.oid = e.enumtypid
    WHERE t.typname = 'item_status'
      AND e.enumlabel = 'paid'
  ) THEN
    ALTER TYPE public.item_status ADD VALUE 'paid';
  END IF;
END$$;

-- Columna de cierre en order_checks (para historial)
ALTER TABLE public.order_checks
  ADD COLUMN IF NOT EXISTS closed_at timestamptz;
