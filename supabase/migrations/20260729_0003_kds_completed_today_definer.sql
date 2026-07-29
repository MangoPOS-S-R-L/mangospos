-- =============================================================================
-- 20260729_0003 — Corrige regresión: kds_completed_today vuelve a definer
-- =============================================================================
--
-- La vista VIVA en producción corría SIN security_invoker (como definer,
-- igual que kds_active_items y kds_open_orders) y el historial se veía bien.
-- La migración 20260729_0001 la recreó con `with (security_invoker = on)`
-- copiado del archivo del repo 20260616_0003 — que NUNCA coincidió con lo
-- vivo (BD diverge del repo). Con invoker activo, el RLS de order_items
-- (`business_id IN current_user_business_ids()`) esconde filas con
-- oi.business_id NULL → "Completados hoy" pasó a 0 en la app.
--
-- Fix: reset del reloption → la vista vuelve a ejecutarse como su dueño
-- (paridad con el resto de la familia KDS y con el comportamiento previo).
-- El WHERE nuevo de 20260729_0001 (incluir cobradas sin marcar) SE CONSERVA.
--
-- La RPC fn_kds_completed_today (20260729_0002) sigue siendo el camino
-- preferido de la app (valida user_has_business_access); esta vista queda
-- como fallback y para builds viejos que consultan la vista directo.
--
-- IDEMPOTENTE: RESET no falla si la opción ya no está.
-- =============================================================================

begin;

alter view public.kds_completed_today reset (security_invoker);

commit;
