-- Agregar columnas de cliente a la tabla payments
-- Requerido para el funcionamiento del nuevo RPC de pagos v2
-- Fecha: 2026-02-07

-- 1. Agregar customer_id (nullable, FK a customers)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'payments' AND column_name = 'customer_id'
  ) THEN
    ALTER TABLE public.payments 
    ADD COLUMN customer_id uuid REFERENCES public.customers(id);
  END IF;
END $$;

-- 2. Agregar customer_rnc (nullable, texto)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'payments' AND column_name = 'customer_rnc'
  ) THEN
    ALTER TABLE public.payments 
    ADD COLUMN customer_rnc text;
  END IF;
END $$;

-- 3. Crear índice para optimizar búsquedas de pagos por cliente
CREATE INDEX IF NOT EXISTS idx_payments_customer_id 
ON public.payments(customer_id);

-- 4. Actualizar metadata de Postgrest
NOTIFY pgrst, 'reload config';
