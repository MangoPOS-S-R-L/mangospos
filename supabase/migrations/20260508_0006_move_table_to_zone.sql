-- =============================================================================
-- Migration: fn_move_table_to_zone (F1 del PRD-12 Mover/Unir Mesas)
-- Purpose : Cambiar la zona a la que pertenece una dining_table sin tocar
--           sus sesiones / órdenes. Caso típico: mesa T05 pasa de "Salón
--           Principal" a "Terraza" porque se reorganiza el restaurante.
--
-- No afecta:
--   - table_sessions abiertas (siguen apuntando al mismo table_id)
--   - orders / order_items
--   - state de la mesa (available/occupied) — se preserva
--
-- Seguridad:
--   - SECURITY DEFINER, valida manualmente que el caller sea admin del
--     business al que pertenecen ambas zonas (origen y destino).
--   - Bloquea cross-business: si la zona destino no es del mismo business
--     que la origen, falla con SAME_BUSINESS_REQUIRED.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_move_table_to_zone(
  p_table_id        uuid,
  p_target_zone_id  uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_business_id     uuid;
  v_source_zone_id  uuid;
  v_target_business uuid;
BEGIN
  IF p_table_id IS NULL OR p_target_zone_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_INPUT';
  END IF;

  -- Mesa origen + business via la zona origen.
  SELECT t.zone_id, z.business_id
    INTO v_source_zone_id, v_business_id
  FROM public.dining_tables t
  JOIN public.zones z ON z.id = t.zone_id
  WHERE t.id = p_table_id;

  IF v_source_zone_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  -- Zona destino debe existir y pertenecer al mismo business.
  SELECT business_id INTO v_target_business
  FROM public.zones
  WHERE id = p_target_zone_id;

  IF v_target_business IS NULL THEN
    RAISE EXCEPTION 'TARGET_ZONE_NOT_FOUND';
  END IF;

  IF v_target_business <> v_business_id THEN
    RAISE EXCEPTION 'SAME_BUSINESS_REQUIRED';
  END IF;

  IF v_source_zone_id = p_target_zone_id THEN
    -- No-op: la mesa ya está en la zona destino. Devolvemos OK
    -- silencioso para que el cliente no muestre error innecesario.
    RETURN jsonb_build_object(
      'moved', false,
      'reason', 'ALREADY_IN_TARGET_ZONE',
      'table_id', p_table_id,
      'zone_id', p_target_zone_id
    );
  END IF;

  -- RBAC: solo admins del business pueden reorganizar mesas.
  -- is_admin_of_business ya existe en el schema y es la función
  -- canónica para este check (igual que en print_areas, bank_accounts).
  IF NOT public.is_admin_of_business(v_business_id) THEN
    RAISE EXCEPTION 'NOT_AUTHORIZED';
  END IF;

  UPDATE public.dining_tables
  SET zone_id = p_target_zone_id
  WHERE id = p_table_id;

  RETURN jsonb_build_object(
    'moved', true,
    'table_id', p_table_id,
    'source_zone_id', v_source_zone_id,
    'target_zone_id', p_target_zone_id,
    'business_id', v_business_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_move_table_to_zone(uuid, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.fn_move_table_to_zone(uuid, uuid) IS
  'PRD-12 F1: cambia dining_tables.zone_id sin tocar sesiones ni órdenes. '
  'Valida que ambas zonas (origen y destino) pertenezcan al mismo business '
  'y que el caller sea admin del business.';
