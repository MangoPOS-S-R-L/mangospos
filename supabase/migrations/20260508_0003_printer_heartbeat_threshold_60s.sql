-- =============================================================================
-- Migration: bajar threshold de "stale heartbeat" de 90s a 60s
-- Purpose : Detectar impresoras / device agents desconectados más rápido.
--           El scheduler Dart pingea cada 30s; 60s = tolera UN ping perdido
--           (margen prudente) en vez de 3. Detection window pasa de 60-90s
--           a 30-60s.
--
-- Cambios:
--   1. fn_mark_stale_printers_offline: 90s → 60s
--   2. fn_mark_stale_device_agents_offline: 90s → 60s
--
-- Riesgo: si el agente local tiene un glitch transitorio (ej. CPU pico),
-- una impresora podría marcarse offline brevemente. La próxima ronda de
-- heartbeat (30s después) la regresa a online. Aceptable — el fallback
-- de impresión por agente local sigue cubriendo ese caso.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_mark_stale_printers_offline()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.printers
  SET online = false
  WHERE online = true
    AND (
      last_heartbeat_at IS NULL
      OR last_heartbeat_at < now() - interval '60 seconds'
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_mark_stale_printers_offline() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_mark_stale_printers_offline() TO service_role;

CREATE OR REPLACE FUNCTION public.fn_mark_stale_device_agents_offline()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.device_agents
  SET online = false,
      updated_at = now()
  WHERE online = true
    AND (
      last_heartbeat_at IS NULL
      OR last_heartbeat_at < now() - interval '60 seconds'
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_mark_stale_device_agents_offline()
  TO authenticated, service_role;
