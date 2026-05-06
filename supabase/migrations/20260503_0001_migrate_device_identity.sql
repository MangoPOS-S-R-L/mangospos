-- PRD 5 F5.1 — Migración atómica de device_id (de UUID v4 aleatorio a
-- hardware UUID estable del OS).
--
-- Caso de uso: un Windows que reinstaló el binario y por eso generó un
-- UUID nuevo en SharedPreferences, mientras printers.host_device_id
-- todavía apunta al UUID viejo. Al adoptar el hardware UUID, hay que
-- mover la fila de device_agents y todas las printers de un device_id
-- al otro en una sola transacción.
--
-- Diseño: en una sola sentencia SECURITY DEFINER hacemos:
--   1. INSERT into device_agents con los datos del row viejo, usando
--      el new_id como PK. ON CONFLICT DO UPDATE actualiza datos si la
--      fila nueva ya existía.
--   2. UPDATE printers SET host_device_id = new_id WHERE host_device_id = old_id.
--   3. DELETE FROM device_agents WHERE id = old_id (la FK
--      `printers.host_device_id REFERENCES device_agents(id) ON DELETE
--      SET NULL` ya no aplica porque movimos las printers en el paso 2).

CREATE OR REPLACE FUNCTION "public"."fn_migrate_device_identity"(
  "p_old_id" "uuid",
  "p_new_id" "uuid",
  "p_business_id" "uuid"
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_device_name text;
  v_agent_url text;
  v_platform text;
  v_online boolean;
  v_last_hb timestamp with time zone;
BEGIN
  IF p_old_id IS NULL OR p_new_id IS NULL OR p_business_id IS NULL THEN
    RAISE EXCEPTION 'fn_migrate_device_identity: parameters required';
  END IF;
  IF p_old_id = p_new_id THEN
    RETURN; -- nada que hacer
  END IF;

  -- Snapshot del row viejo (puede no existir si el device nunca registró
  -- agent — en ese caso solo hay que mover las printers).
  SELECT device_name, agent_url, platform, online, last_heartbeat_at
    INTO v_device_name, v_agent_url, v_platform, v_online, v_last_hb
  FROM public.device_agents
  WHERE id = p_old_id AND business_id = p_business_id;

  -- Crear/actualizar fila con el nuevo id, conservando datos del viejo.
  INSERT INTO public.device_agents (
    id, business_id, device_name, agent_url, platform,
    online, last_heartbeat_at, created_at, updated_at
  ) VALUES (
    p_new_id, p_business_id, v_device_name, v_agent_url, v_platform,
    coalesce(v_online, false), v_last_hb, now(), now()
  )
  ON CONFLICT (id) DO UPDATE SET
    device_name = COALESCE(EXCLUDED.device_name, device_agents.device_name),
    agent_url = COALESCE(EXCLUDED.agent_url, device_agents.agent_url),
    platform = COALESCE(EXCLUDED.platform, device_agents.platform),
    online = EXCLUDED.online,
    last_heartbeat_at = EXCLUDED.last_heartbeat_at,
    updated_at = now();

  -- Mover printers.host_device_id del viejo al nuevo.
  UPDATE public.printers
     SET host_device_id = p_new_id
   WHERE host_device_id = p_old_id;

  -- Borrar fila vieja (las printers ya no la referencian).
  DELETE FROM public.device_agents WHERE id = p_old_id;
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_migrate_device_identity"("uuid", "uuid", "uuid") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_migrate_device_identity"("uuid", "uuid", "uuid") TO "service_role";

-- ═══════════════════════════════════════════════════════════════════════════════
-- Smoke check
-- ═══════════════════════════════════════════════════════════════════════════════
-- Antes:
--   SELECT id, device_name FROM device_agents WHERE business_id = '<biz>';
--   SELECT id, name, host_device_id FROM printers WHERE business_id = '<biz>';
--
-- Ejecutar:
--   SELECT public.fn_migrate_device_identity(
--     '<old-uuid>'::uuid,
--     '<new-hardware-uuid>'::uuid,
--     '<biz>'::uuid
--   );
--
-- Después: la fila vieja debe estar borrada, la nueva con los mismos datos,
-- y las printers deben apuntar al nuevo id.
