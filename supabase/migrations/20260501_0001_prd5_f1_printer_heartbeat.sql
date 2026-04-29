-- PRD 5 — Fase 1: Foundations del módulo de impresión unificado
--
-- Cambios:
--   1. Agrega `printers.bluetooth_address` y `printers.last_heartbeat_at`.
--   2. Índice único `(business_id, name)` para evitar duplicados accidentales
--      al usar el wizard "Agregar impresora" o cuando un user multi-business
--      asigna la misma impresora física a múltiples áreas (AD5-7 — el dispositivo
--      es uno; las múltiples asignaciones se manejan via print_area_printers).
--   3. RPC `fn_printer_heartbeat(p_printer_id)` que marca online + actualiza
--      timestamp. Llamada desde el agent local cada 30s.
--   4. RPC `fn_mark_stale_printers_offline()` que pasa a offline cualquier
--      impresora sin heartbeat reciente (default 90s). Pensada para correr
--      vía pg_cron cada 30s.
--   5. Programar pg_cron para invocar #4 (si la extensión está disponible).
--
-- NO se modifica el enum `printer_type` en esta fase — PRD difería esto a F3
-- cuando agreguemos bluetooth_classic vs bluetooth_le. Los valores actuales
-- (network/bluetooth/usb) siguen intactos.
--
-- NO se borra ninguna columna existente: backwards-compatible total.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Nuevas columnas en printers
-- ═══════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.printers
  ADD COLUMN IF NOT EXISTS bluetooth_address text;

ALTER TABLE public.printers
  ADD COLUMN IF NOT EXISTS last_heartbeat_at timestamp with time zone;

COMMENT ON COLUMN public.printers.bluetooth_address IS
  'MAC address de impresora Bluetooth (clásica o BLE). NULL para impresoras LAN/USB. Se separa de `mac` que históricamente se usó para MAC ethernet de impresoras de red.';

COMMENT ON COLUMN public.printers.last_heartbeat_at IS
  'Última vez que el agent local reportó esta impresora como disponible. Distinto de `last_seen`: heartbeat = ping activo del agent, last_seen = última observación (puede ser de print job exitoso, no solo heartbeat).';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Índice único para evitar duplicados de nombre por business
-- ═══════════════════════════════════════════════════════════════════════════════

-- Crear índice solo si no existe ya
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'printers'
      AND indexname = 'idx_printers_business_name_unique'
  ) THEN
    CREATE UNIQUE INDEX idx_printers_business_name_unique
      ON public.printers (business_id, name)
      WHERE is_active = true;
  END IF;
END $$;

COMMENT ON INDEX public.idx_printers_business_name_unique IS
  'Evita 2 impresoras activas con el mismo nombre dentro de un business. Permite duplicados en histórico (is_active=false) para auditoría.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. RPC heartbeat: agent llama cada 30s
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_printer_heartbeat(p_printer_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  UPDATE public.printers
  SET online = true,
      last_seen = now(),
      last_heartbeat_at = now()
  WHERE id = p_printer_id
    AND is_active = true;

  -- No raise exception si no se encontró: el agent no necesita saber la causa
  -- (impresora borrada, deshabilitada, etc.). Simplemente sigue su loop.
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_printer_heartbeat(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.fn_printer_heartbeat(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_printer_heartbeat(uuid) TO service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. RPC para marcar offline las impresoras sin heartbeat reciente
-- ═══════════════════════════════════════════════════════════════════════════════
-- Threshold de 90s permite tolerar un heartbeat perdido (agent cada 30s).
-- Después de 3 heartbeats perdidos asumimos que el agent o la impresora cayó.

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
      OR last_heartbeat_at < now() - interval '90 seconds'
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_mark_stale_printers_offline() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_mark_stale_printers_offline() TO service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. pg_cron: agendar la limpieza cada 30s (si la extensión está disponible)
-- ═══════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  -- Verificar si pg_cron está instalado (típicamente sí en Supabase)
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Borrar job previo si existe (idempotente)
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname = 'mark_stale_printers_offline';

    -- Agendar nuevo: cada 30s
    PERFORM cron.schedule(
      'mark_stale_printers_offline',
      '30 seconds',
      $cron$SELECT public.fn_mark_stale_printers_offline()$cron$
    );
  ELSE
    RAISE NOTICE 'pg_cron no disponible. Tendrás que invocar fn_mark_stale_printers_offline() manualmente o desde el agent.';
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  -- En entornos donde el usuario que aplica la migration no tiene permiso de
  -- cron, no rompemos. El admin puede agendarlo manualmente después.
  RAISE NOTICE 'No se pudo agendar pg_cron job (privilegio insuficiente). Agendar manualmente con: SELECT cron.schedule(''mark_stale_printers_offline'', ''30 seconds'', ''SELECT public.fn_mark_stale_printers_offline()'');';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. Backfill: marcar online=false las que ya están stale al deploy
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT public.fn_mark_stale_printers_offline();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. RLS: las RPC son SECURITY DEFINER, pero las consultas directas a la tabla
--     respetan la política existente "printers RLS" basada en business_id.
--     No hace falta agregar nada nuevo aquí.
-- ═══════════════════════════════════════════════════════════════════════════════
