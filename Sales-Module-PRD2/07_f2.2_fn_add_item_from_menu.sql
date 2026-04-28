-- =============================================================================
-- File:        07_f2.2_fn_add_item_from_menu.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes
-- Rollback:    rollback/07_restore_fn_add_item_from_menu.sql
--
-- Purpose:
--   Reescribe `fn_add_item_from_menu` con el modelo unificado (PRD §6.6
--   ajustado por OQ2-5 = A).
--
--   Cambios respecto al estado pre-PRD-2:
--
--   1) ELIMINADO: lectura de `business_settings` (G2).
--      No más fallback a `service_fee_*` ni a `default_tax_rate`. Si el
--      negocio no configuró el impuesto, no se cobra. Punto.
--
--   2) ELIMINADO: cálculo separado de `v_service_fee_rate`. La propina
--      ahora pasa por `menu_item_taxes` como cualquier otro impuesto
--      (OQ2-5 = A). `fn_resolve_order_item_tax_profile` ya devuelve
--      la suma incluyendo propina.
--
--   3) ELIMINADO: branches del CASE con valores fantasma del enum
--      (`table`, `zone`, `table_order`, `manual_order`, `quick_sale`,
--      `quick-sale`, LIKE '%delivery%'). Sólo los 4 valores reales del
--      enum se aceptan como transaccionales.
--
--   4) AGREGADO: fail-loud para `self_service` y origins desconocidos
--      (OQ2-1 = B).
--
--   5) `original_tax_rate` se calcula como la suma de TODOS los taxes
--      asociados al producto (sin filtro origin). Esto preserva la
--      base estable en modo inclusive cuando un origin desactiva un
--      impuesto (el precio mostrado no cambia, sólo cambia la
--      composición interna).
--
--   El INSERT al order_items dispara `fn_compute_item_totals` (BEFORE)
--   que setea subtotal/tax/total, y `fn_populate_tax_lines` (AFTER) que
--   poblará `order_item_tax_lines`.
--
-- Apply order:
--   1. Staging.
--   2. Después de SQL 06 (depende de fn_resolve_order_item_tax_profile
--      simplificado).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_add_item_from_menu(
  p_order_id        uuid,
  p_menu_item_id    uuid,
  p_qty             numeric DEFAULT 1,
  p_check_position  integer DEFAULT 1,
  p_is_takeout      boolean DEFAULT false,
  p_notes           text    DEFAULT NULL::text
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_name              text;
  v_price             numeric(12,2);
  v_print_area_code   text;
  v_origin            text;
  v_biz_id            uuid;
  v_tax_mode          text;
  v_tax_rate          numeric := 0;
  v_full_tax_rate     numeric := 0;
  v_check             uuid;
  v_item_id           uuid;
  v_qty               numeric(10,3);
BEGIN
  v_qty := greatest(coalesce(p_qty, 1), 1);

  -- 1. Producto
  SELECT name, price, coalesce(print_area_code, 'kitchen_hot')
    INTO v_name, v_price, v_print_area_code
  FROM public.menu_items
  WHERE id = p_menu_item_id
  LIMIT 1;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  -- 2. Origin + business
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO v_origin, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  -- Fail-loud (OQ2-1)
  IF v_origin = 'self_service' THEN
    RAISE EXCEPTION 'self_service origin not supported (PRD 2 fail-loud): self-checkout aún no implementado';
  END IF;

  IF v_origin IS NULL OR v_origin NOT IN ('dine_in', 'manual', 'quick', 'delivery') THEN
    RAISE EXCEPTION 'unknown order_origin: %', v_origin;
  END IF;

  -- 3. Resolución de impuestos (modelo unificado, OQ2-5 = A)
  --
  --    v_tax_rate      = suma de taxes que aplican AL ORIGIN
  --                      (lo que se cobra realmente al cliente)
  --    v_full_tax_rate = suma de TODOS los taxes asociados al producto
  --                      (sin filtro origin) → necesario para que el
  --                      modo inclusive extraiga la base estable
  --                      aunque un origin desactive un impuesto.
  --
  --    Si el item es takeout, los taxes con is_service_fee=true no
  --    aplican (regla de propina takeout) → se restan de ambos.

  SELECT profile.tax_mode, profile.tax_rate
    INTO v_tax_mode, v_tax_rate
  FROM public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

  -- v_tax_rate viene incluyendo la propina si aplica al origin. Si es
  -- takeout, restamos las tasas de impuestos service_fee.
  IF coalesce(p_is_takeout, false) THEN
    SELECT coalesce(v_tax_rate, 0) - coalesce(sum(t.rate), 0)
      INTO v_tax_rate
    FROM public.menu_item_taxes mit
    JOIN public.taxes t ON t.id = mit.tax_id
    WHERE mit.item_id = p_menu_item_id
      AND t.business_id = v_biz_id
      AND coalesce(t.is_active, true)
      AND coalesce(t.is_service_fee, false)
      AND (
        (v_origin = 'dine_in'  AND t.apply_on_zone)     OR
        (v_origin = 'manual'   AND t.apply_on_manual)   OR
        (v_origin = 'quick'    AND t.apply_on_quick)    OR
        (v_origin = 'delivery' AND t.apply_on_delivery)
      );

    v_tax_rate := greatest(coalesce(v_tax_rate, 0), 0);
  END IF;

  -- v_full_tax_rate: TODOS los taxes asociados al producto (sin filtrar
  -- por origin). En takeout también descontamos service_fee porque la
  -- propina takeout nunca se compuso en el precio.
  SELECT coalesce(sum(t.rate), 0)::numeric
    INTO v_full_tax_rate
  FROM public.menu_item_taxes mit
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE mit.item_id = p_menu_item_id
    AND t.business_id = v_biz_id
    AND coalesce(t.is_active, true)
    AND NOT (coalesce(p_is_takeout, false) AND coalesce(t.is_service_fee, false));

  -- 4. Crear/usar check
  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  -- 5. Insertar item. Triggers se encargan de subtotal/tax/total y de
  -- poblar order_item_tax_lines.
  INSERT INTO public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, tax_mode, tax_rate, original_tax_rate,
    is_takeout, notes, status, print_area_code
  ) VALUES (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, v_qty, v_price, coalesce(v_tax_mode, 'exclusive'),
    coalesce(v_tax_rate, 0), coalesce(v_full_tax_rate, 0),
    coalesce(p_is_takeout, false), p_notes, 'draft',
    v_print_area_code
  )
  RETURNING id INTO v_item_id;

  -- 6. Recalcular totales del order (delegado al motor unificado).
  PERFORM public.fn_recalc_totals(p_order_id);
  RETURN v_item_id;
END;
$function$;
