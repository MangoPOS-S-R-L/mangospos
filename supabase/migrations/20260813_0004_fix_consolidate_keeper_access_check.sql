-- =============================================================================
-- 20260813_0004 — Fix 42703 "column c.bid does not exist" al dividir cuentas
-- =============================================================================
--
-- SÍNTOMA: en División de cuentas, al pulsar "Aplicar división" salía
--   `Error al consolidar items de subcuenta: PostgrestException(message:
--    column c.bid does not exist, code: 42703)`. Pero al salir y volver a
--   entrar, la cuenta SÍ aparecía dividida.
--
--   Esa contradicción es la firma del bug: el reparto de items ya se escribió,
--   y lo que revienta es el paso final de consolidación
--   (`fn_consolidate_keeper_atomic`). El usuario ve un error sobre trabajo que
--   en realidad quedó hecho a medias — sin el UPDATE del keeper ni el refresh
--   de `order_item_tax_lines`.
--
-- CAUSA: el access check de la función hace
--
--     SELECT 1 FROM public.current_user_business_ids() c WHERE c.bid = ...
--
--   `current_user_business_ids()` devuelve **SETOF uuid** desde
--   20260708_0001, así que su única columna se llama `current_user_business_ids`.
--   Sin alias EXPLÍCITO de columna, cualquier `c.<lo que sea>` lanza 42703
--   para el caller `authenticated` (la app). Con service_role el chequeo se
--   salta entero, que es por qué a mano en el SQL Editor "funciona".
--
--   Es exactamente el mismo fallo que ya se corrigió en 20260710_0001
--   (get_products_by_production_area) y 20260717_0001 (fn_mall_sales_by_hour).
--
-- FIX: `AS c(business_id)`. El alias explícito funciona igual si la función
--   devuelve SETOF uuid o TABLE(business_id uuid), así que no vuelve a
--   romperse si algún día cambia la firma.
--
-- ⚠ ANTES DE APLICAR — esta base diverge del repo (el vivo dice `c.bid`, el
--   repo decía `c.business_id`), así que el resto del cuerpo puede diferir.
--   Comparar primero:
--
--     SELECT pg_get_functiondef('public.fn_consolidate_keeper_atomic(uuid,uuid[],numeric,numeric)'::regprocedure);
--
--   Si el cuerpo vivo tiene algo que no está aquí, NO apliques esta migración
--   tal cual: copia el cuerpo vivo y cámbiale solo la línea del access check.
--
-- IDEMPOTENTE: CREATE OR REPLACE. No toca datos.
-- =============================================================================

begin;

CREATE OR REPLACE FUNCTION public.fn_consolidate_keeper_atomic(
  p_keeper_id    uuid,
  p_remove_ids   uuid[],
  p_sum_qty      numeric,
  p_sum_discounts numeric
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_business_id uuid;
BEGIN
  IF p_keeper_id IS NULL THEN
    RAISE EXCEPTION 'KEEPER_ID_REQUIRED';
  END IF;

  -- Resolver business_id del keeper para validar acceso.
  SELECT ts.business_id
    INTO v_business_id
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE oi.id = p_keeper_id;

  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'KEEPER_NOT_FOUND: %', p_keeper_id
      USING ERRCODE = '42P01';
  END IF;

  -- Access check: service_role salta, authenticated valida pertenencia.
  IF auth.role() <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.current_user_business_ids() AS c(business_id)
      WHERE c.business_id = v_business_id
    ) THEN
      RAISE EXCEPTION 'access denied' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Si vienen ids a borrar, validar que ninguno cruza business (defensa
  -- ante un caller malicioso que pase ids de otro negocio).
  IF p_remove_ids IS NOT NULL AND array_length(p_remove_ids, 1) > 0 THEN
    IF EXISTS (
      SELECT 1
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
      JOIN public.table_sessions ts ON ts.id = o.session_id
      WHERE oi.id = ANY(p_remove_ids)
        AND ts.business_id <> v_business_id
    ) THEN
      RAISE EXCEPTION 'REMOVE_IDS_CROSS_BUSINESS' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- (1) UPDATE keeper. El trigger fn_compute_item_totals recompute
  -- subtotal/tax/total automáticamente con la nueva qty consolidada.
  -- Si el UPDATE no afecta filas (keeper desapareció entre el SELECT
  -- del caller y este UPDATE), abortamos — no queremos DELETE huérfano.
  UPDATE public.order_items
  SET qty       = p_sum_qty,
      quantity  = ROUND(p_sum_qty)::int,
      discounts = COALESCE(p_sum_discounts, 0)
  WHERE id = p_keeper_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'KEEPER_UPDATE_NO_ROW: % ya no existe', p_keeper_id
      USING ERRCODE = 'P0002';
  END IF;

  -- (2) Self-heal: si el keeper es un clone roto del split viejo
  -- (tax_rate=0 + tax_mode='exclusive') pero su producto sí está
  -- registrado con impuestos en menu_item_taxes, restauramos los valores
  -- correctos desde menu_items. Esto convierte el merge en el punto donde
  -- se reparan automáticamente las órdenes históricas con clones rotos.
  -- Items legítimamente exentos quedan intactos (el EXISTS los excluye).
  UPDATE public.order_items oi
  SET
    tax_rate = (
      SELECT COALESCE(SUM(t.rate), 0)
      FROM public.menu_item_taxes mit
      JOIN public.taxes t ON t.id = mit.tax_id
      JOIN public.orders o2 ON o2.id = oi.order_id
      JOIN public.table_sessions ts2 ON ts2.id = o2.session_id
      WHERE mit.item_id = oi.product_id
        AND COALESCE(t.is_active, true)
        AND (NOT COALESCE(oi.is_takeout, false) OR COALESCE(t.apply_on_takeout, true) = true)
        AND (
          (trim(lower(ts2.origin::text)) IN ('dine_in','table','zone','table_order') AND t.apply_on_zone = true) OR
          (trim(lower(ts2.origin::text)) IN ('manual','manual_order') AND t.apply_on_manual = true) OR
          (trim(lower(ts2.origin::text)) IN ('quick','quick_sale','quick-sale') AND t.apply_on_quick = true) OR
          ((trim(lower(ts2.origin::text)) = 'delivery' OR trim(lower(ts2.origin::text)) LIKE '%delivery%') AND t.apply_on_delivery = true) OR
          (ts2.origin IS NULL OR trim(lower(ts2.origin::text)) NOT IN (
            'dine_in','table','zone','table_order',
            'manual','manual_order',
            'quick','quick_sale','quick-sale',
            'delivery'
          ))
        )
    ),
    tax_mode = COALESCE(
      (SELECT mi.tax_mode FROM public.menu_items mi WHERE mi.id = oi.product_id),
      'exclusive'
    )
  WHERE oi.id = p_keeper_id
    AND oi.tax_rate = 0
    AND oi.tax_mode = 'exclusive'
    AND EXISTS (
      SELECT 1 FROM public.menu_item_taxes mit2
      WHERE mit2.item_id = oi.product_id
    );

  -- (3) DELETE de los duplicados consolidados. Excluye explícitamente el
  -- keeper como salvavidas extra (si el caller se equivocó y lo incluyó).
  IF p_remove_ids IS NOT NULL AND array_length(p_remove_ids, 1) > 0 THEN
    DELETE FROM public.order_items
    WHERE id = ANY(p_remove_ids)
      AND id <> p_keeper_id;
  END IF;

  -- (4) Refrescar tax_lines del keeper basado en el subtotal recién
  -- calculado por el trigger (que ya consideró el tax_rate/tax_mode
  -- restaurado en el paso 2). Sin esto, las tax_lines del keeper reflejan
  -- el estado pre-consolidación y el breakdown del display se desincroniza.
  PERFORM public.fn_populate_item_tax_lines(p_keeper_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_consolidate_keeper_atomic(uuid, uuid[], numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_consolidate_keeper_atomic(uuid, uuid[], numeric, numeric) TO authenticated;

commit;

-- =============================================================================
-- VERIFICACIÓN
-- =============================================================================
-- 1) Ya no debe quedar un acceso sin alias de columna. Esperado: 0 filas.
-- SELECT 1
--   FROM pg_proc p
--  WHERE p.proname = 'fn_consolidate_keeper_atomic'
--    AND pg_get_functiondef(p.oid) LIKE '%current_user_business_ids() c%';
--
-- 2) Desde la app: dividir una cuenta y pulsar "Aplicar división". Debe
--    cerrar sin error y con los totales de cada subcuenta ya cuadrados,
--    sin tener que salir y volver a entrar.
-- =============================================================================
