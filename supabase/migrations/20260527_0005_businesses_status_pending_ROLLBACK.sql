-- Rollback de 20260527_0005_businesses_status_pending.sql
-- ATENCIÓN: si hay businesses con status='pending' en BD, hay que actualizarlos
-- a 'active' o 'inactive' ANTES de correr este rollback, sino el ADD CONSTRAINT falla.
--
-- Pre-check sugerido:
--   SELECT count(*) FROM public.businesses WHERE status = 'pending';
--   -- Si > 0:
--   UPDATE public.businesses SET status = 'active' WHERE status = 'pending';

ALTER TABLE public.businesses
  DROP CONSTRAINT IF EXISTS businesses_status_check;

ALTER TABLE public.businesses
  ADD CONSTRAINT businesses_status_check
  CHECK (status IN ('active', 'inactive'));
