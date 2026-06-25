-- =============================================================================
-- Backfill one-time: cerrar los order_checks HUÉRFANOS creados antes del fix
-- 20260624_0001 (cobro a nivel de orden no cerraba los checks).
--
-- Huérfano = check con is_closed=false cuya orden YA está cerrada/pagada/anulada.
-- Footprint medido 2026-06-24: ~40,000 filas en 36 negocios. La mayoría son
-- inofensivos (solo un flag colgado); este backfill alinea el estado para que
-- ningún check de una orden cerrada siga apareciendo como cuenta abierta.
--
-- Seguro: el único trigger en order_checks (trg_check_max_checks) es BEFORE
-- INSERT, no se dispara en UPDATE. Idempotente (WHERE is_closed=false). No
-- recursa. closed_at toma, en orden, el del propio check, el de la orden, o now().
--
-- A partir de 20260624_0001 ya no se generan nuevos huérfanos, así que este
-- backfill solo limpia el backlog histórico y no necesita repetirse.
-- =============================================================================

UPDATE public.order_checks oc
SET is_closed = true,
    closed_at = COALESCE(oc.closed_at, o.closed_at, now())
FROM public.orders o
WHERE oc.order_id = o.id
  AND COALESCE(oc.is_closed, false) = false
  AND (o.closed_at IS NOT NULL OR o.status_ext IN ('paid', 'void'));
