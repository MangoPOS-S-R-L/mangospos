-- =============================================================================
-- Consolidate atomic: UPDATE keeper + self-heal de tax_rate/tax_mode si el
-- keeper era un clone roto + DELETE de duplicados + refresh de tax_lines.
-- Todo en una sola transacción Postgres.
--
-- Por qué hace falta atomicidad:
-- En `ReportsRepository.consolidateCheckItems` (Flutter), el patrón previo
-- hacía dos llamadas separadas:
--   1. _client.from('order_items').update(...).eq('id', keeper_id)
--   2. _client.from('order_items').delete().inFilter('id', remove_ids)
-- Si el UPDATE silenciaba un error (timeout, RLS, trigger fallido) pero el
-- DELETE corría igual, se perdían TODOS los items del grupo (incluido el
-- keeper que nunca se actualizó). Caso real observado: 6 CARAMEL CAPUCHINO
-- de RD$ 180 c/u desaparecieron de una mesa, dejando un faltante de
-- RD$ 1,080 que el cajero no podía explicar.
--
-- Por qué el self-heal:
-- Aunque la migración 0002 arregla `fn_split_items_equally` para que
-- futuros splits no creen clones rotos, las órdenes que ya pasaron por la
-- versión vieja del split tienen items con tax_rate=0 y tax_mode='exclusive'
-- por column default. Cuando el cajero merge esas subcuentas, el keeper
-- queda con su estado roto y sigue produciendo NCFs con ITBIS inflado y
-- displays incoherentes. El self-heal detecta esa condición específica
-- (tax_rate=0 + tax_mode='exclusive' + el producto SÍ tiene menu_item_taxes)
-- y restaura los valores correctos desde `menu_items` antes del refresh
-- de tax_lines. Items legítimamente exentos (sin menu_item_taxes) no se
-- tocan.
--
-- Esta función envuelve las cuatro operaciones (UPDATE qty, self-heal,
-- DELETE, populate tax_lines) en una única transacción plpgsql. Si cualquier
-- paso falla, rollback completo. Imposible terminar en un estado parcial.
--
-- Valida acceso por business_id (mismo patrón que get_sales_summary_v2).
-- =============================================================================

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
      SELECT 1 FROM public.current_user_business_ids() c
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

COMMENT ON FUNCTION public.fn_consolidate_keeper_atomic(uuid, uuid[], numeric, numeric) IS
  'Atomic consolidate: UPDATE keeper + self-heal de tax_rate/tax_mode si era clone roto + DELETE duplicados + refresh tax_lines, todo en una transacción. Repara automáticamente órdenes históricas con clones del split viejo al momento de unir subcuentas.';
