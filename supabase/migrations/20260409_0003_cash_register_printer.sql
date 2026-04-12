-- =============================================================================
-- Migration: receipt_printer_id on cash_registers
-- Purpose: Allow admin to assign a receipt printer to each cash register.
--          Falls back to global area-based lookup if not set.
-- =============================================================================

-- 1. Add receipt_printer_id to cash_registers
ALTER TABLE public.cash_registers
  ADD COLUMN IF NOT EXISTS receipt_printer_id uuid REFERENCES public.printers(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.cash_registers.receipt_printer_id
  IS 'Optional: specific printer for receipts/invoices printed from this register. Falls back to global print area config if NULL.';

-- 2. Index for quick lookups
CREATE INDEX IF NOT EXISTS idx_cash_registers_receipt_printer
  ON public.cash_registers(receipt_printer_id)
  WHERE receipt_printer_id IS NOT NULL;
