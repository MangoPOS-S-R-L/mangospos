-- =============================================================================
-- File:        06_f2.2_fn_resolve_order_item_tax_profile.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes
-- Rollback:    rollback/06_restore_fn_resolve_order_item_tax_profile.sql
--
-- Purpose:
--   Simplifica `fn_resolve_order_item_tax_profile` y le aplica las
--   3 reglas del PRD 2:
--
--   1) OQ2-5 = A: NO filtrar `is_service_fee=false`. Todos los taxes
--      del producto que apliquen al origin se suman, incluyendo propina.
--
--   2) G3: eliminar valores fantasma del enum (`table`, `zone`,
--      `table_order`, `manual_order`, `quick_sale`, `quick-sale`,
--      LIKE '%delivery%'). El enum real sólo tiene 5 valores y solo
--      4 son válidos como input transaccional (`dine_in`, `manual`,
--      `quick`, `delivery`); `self_service` es fail-loud.
--
--   3) OQ2-1 = B: fail-loud para `self_service` y origins desconocidos.
--      Antes había una rama default que aplicaba el tax igualmente —
--      eso era código permisivo que escondía bugs.
--
-- Apply order:
--   1. Staging.
--   2. Antes del SQL 07 (que reescribe fn_add_item_from_menu y la llama).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_resolve_order_item_tax_profile(
  p_product_id uuid,
  p_order_id   uuid
)
 RETURNS TABLE(tax_mode text, tax_rate numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_origin           text;
  v_biz_id           uuid;
  v_product_biz_id   uuid;
  v_tax_mode         text;
  v_tax_rate         numeric := 0;
BEGIN
  -- Origin + business del order:
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO v_origin, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  -- Tax mode + business del producto:
  SELECT coalesce(mi.tax_mode, 'exclusive'), mi.business_id
    INTO v_tax_mode, v_product_biz_id
  FROM public.menu_items mi
  WHERE mi.id = p_product_id;

  -- Si no hay business o el producto no pertenece a este business → 0%.
  -- (Caso edge: producto importado mal, no aplicar nada.)
  IF v_biz_id IS NULL OR v_product_biz_id IS DISTINCT FROM v_biz_id THEN
    RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), 0::numeric;
    RETURN;
  END IF;

  -- Fail-loud: self_service no soportado en PRD 2.
  IF v_origin = 'self_service' THEN
    RAISE EXCEPTION 'self_service origin not supported (PRD 2 fail-loud): self-checkout aún no implementado';
  END IF;

  -- Fail-loud: cualquier origin que no esté en el conjunto válido.
  IF v_origin IS NULL OR v_origin NOT IN ('dine_in', 'manual', 'quick', 'delivery') THEN
    RAISE EXCEPTION 'unknown order_origin: %', v_origin;
  END IF;

  -- Suma de tasas que aplican: TODOS los taxes del producto (incluida propina,
  -- OQ2-5 = A) que apliquen al origin del order.
  SELECT coalesce(sum(t.rate), 0)::numeric
    INTO v_tax_rate
  FROM public.menu_item_taxes mit
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE mit.item_id = p_product_id
    AND t.business_id = v_biz_id
    AND coalesce(t.is_active, true)
    AND (
      (v_origin = 'dine_in'  AND t.apply_on_zone)     OR
      (v_origin = 'manual'   AND t.apply_on_manual)   OR
      (v_origin = 'quick'    AND t.apply_on_quick)    OR
      (v_origin = 'delivery' AND t.apply_on_delivery)
    );

  RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), coalesce(v_tax_rate, 0);
END;
$function$;
