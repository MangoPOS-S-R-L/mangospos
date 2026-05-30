-- Rollback de 20260530_0002. Elimina el trigger y su función.
-- Si se revierte, fd.total puede quedar obsoleto cuando llegan payments
-- post-cierre (sync offline tardío, re-emisiones, backfills).

DROP TRIGGER IF EXISTS trg_recompute_fd_on_payment_change ON public.payments;
DROP FUNCTION IF EXISTS public.trg_fn_recompute_fd_on_payment_change();
