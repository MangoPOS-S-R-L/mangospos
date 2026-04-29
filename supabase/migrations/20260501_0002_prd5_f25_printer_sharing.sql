-- PRD 5 F2.5 — Compartir impresoras locales entre dispositivos
--
-- Problema: USB y Bluetooth son conexiones físicas. Sin esta migración, una
-- impresora USB conectada al Mac de caja solo es accesible desde ese Mac;
-- iPad del mesero, iPhone de delivery, etc. no la ven. Mismo issue con BT.
--
-- Solución: cada device del business registra un "device_agent" — un proxy
-- HTTP local que actúa como host de impresoras locales. Cuando otro device
-- necesita imprimir a una USB/BT que no es suya, busca el agent_url del
-- device host en la LAN y le envía el job.
--
-- Cambios:
--   1. Tabla `device_agents` (un row por device por business)
--   2. RPC `fn_register_device_agent` — upsert al arrancar la app
--   3. RPC `fn_device_agent_heartbeat` — cada 30s desde el scheduler
--   4. RPC `fn_mark_stale_device_agents_offline` — cleanup tras 90s
--   5. Columna `printers.host_device_id` (NULL para network, auto-self para USB/BT)
--
-- Backwards-compatible: las impresoras existentes mantienen `host_device_id = NULL`,
-- el frontend trata NULL como "no requiere host" (caso típico: TCP directo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Tabla device_agents
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.device_agents (
  id uuid PRIMARY KEY,
  business_id uuid NOT NULL,
  device_name text,
  agent_url text,
  platform text,
  online boolean DEFAULT false NOT NULL,
  last_heartbeat_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_device_agents_business
  ON public.device_agents (business_id);

CREATE INDEX IF NOT EXISTS idx_device_agents_business_online
  ON public.device_agents (business_id, online);

COMMENT ON TABLE public.device_agents IS
  'Devices del business que actúan como hosts de impresoras locales (USB/BT). Cada device de la app upserta su row al arrancar y reporta heartbeat cada 30s. Los demás devices consultan agent_url para mandar jobs a impresoras compartidas.';

COMMENT ON COLUMN public.device_agents.id IS
  'UUID v4 generado por la app y persistido en storage local del device. Estable entre reinicios.';

COMMENT ON COLUMN public.device_agents.agent_url IS
  'URL HTTP local del agent del device (típicamente http://<lan_ip>:4000). Se actualiza si la IP cambia.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. RLS policy
-- ═══════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.device_agents ENABLE ROW LEVEL SECURITY;

-- SELECT: cualquier user del business puede ver todos los devices del business.
DROP POLICY IF EXISTS device_agents_select ON public.device_agents;
CREATE POLICY device_agents_select ON public.device_agents
  FOR SELECT
  USING (
    business_id IN (
      SELECT bid FROM public.current_user_business_ids() AS bid
    )
  );

-- INSERT/UPDATE: idem (cualquier user del business puede registrar/actualizar
-- devices del business — la app misma autoriza por sus credenciales).
DROP POLICY IF EXISTS device_agents_modify ON public.device_agents;
CREATE POLICY device_agents_modify ON public.device_agents
  FOR ALL
  USING (
    business_id IN (
      SELECT bid FROM public.current_user_business_ids() AS bid
    )
  )
  WITH CHECK (
    business_id IN (
      SELECT bid FROM public.current_user_business_ids() AS bid
    )
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. RPC: registrar/actualizar device agent (idempotente)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_register_device_agent(
  p_id uuid,
  p_business_id uuid,
  p_device_name text,
  p_agent_url text,
  p_platform text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.device_agents (
    id, business_id, device_name, agent_url, platform,
    online, last_heartbeat_at, created_at, updated_at
  ) VALUES (
    p_id, p_business_id, p_device_name, p_agent_url, p_platform,
    true, now(), now(), now()
  )
  ON CONFLICT (id) DO UPDATE SET
    device_name = COALESCE(EXCLUDED.device_name, device_agents.device_name),
    agent_url = COALESCE(EXCLUDED.agent_url, device_agents.agent_url),
    platform = COALESCE(EXCLUDED.platform, device_agents.platform),
    online = true,
    last_heartbeat_at = now(),
    updated_at = now();
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_register_device_agent(uuid, uuid, text, text, text)
  TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. RPC: heartbeat (más liviano que register)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_device_agent_heartbeat(
  p_id uuid,
  p_agent_url text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  UPDATE public.device_agents
  SET online = true,
      last_heartbeat_at = now(),
      agent_url = COALESCE(p_agent_url, agent_url),
      updated_at = now()
  WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_device_agent_heartbeat(uuid, text)
  TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. RPC: mark stale device agents offline (cleanup)
-- ═══════════════════════════════════════════════════════════════════════════════

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
      OR last_heartbeat_at < now() - interval '90 seconds'
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_mark_stale_device_agents_offline()
  TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. printers.host_device_id (FK opcional)
-- ═══════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.printers
  ADD COLUMN IF NOT EXISTS host_device_id uuid REFERENCES public.device_agents(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_printers_host_device
  ON public.printers (host_device_id)
  WHERE host_device_id IS NOT NULL;

COMMENT ON COLUMN public.printers.host_device_id IS
  'Device del business que tiene físicamente conectada esta impresora (USB/BT). NULL para impresoras de red (TCP directo). Cuando otro device del business necesita imprimir, lookup device_agents.agent_url para routing.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. pg_cron schedule (si está disponible)
-- ═══════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname = 'mark_stale_device_agents_offline';

    PERFORM cron.schedule(
      'mark_stale_device_agents_offline',
      '30 seconds',
      $cron$SELECT public.fn_mark_stale_device_agents_offline()$cron$
    );
  ELSE
    RAISE NOTICE 'pg_cron no disponible. La app llama fn_mark_stale_device_agents_offline manualmente desde el scheduler frontend.';
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'No se pudo agendar pg_cron job. La app lo invoca manualmente.';
END $$;
