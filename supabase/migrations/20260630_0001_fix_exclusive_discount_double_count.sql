-- =============================================================================
-- 20260630_0001 — fn_compute_item_totals: descuento se contaba DOBLE
-- =============================================================================
--
-- SÍNTOMA
-- ───────
-- Al aplicar un descuento (ej. 20%) a un item con impuesto EXCLUSIVE, el total
-- bajaba mucho más de lo debido. Ej: Plato del Día 2 = RD$295 base, 28%
-- (10% Ley + 18% ITBIS):
--   - Esperado con 20% off:  295 + impuesto, menos descuento  = RD$302.08
--   - Lo que mostraba/cobraba:                                  RD$205.42
-- Es decir, ~32% de descuento efectivo en vez de 20%. Plata perdida en el cobro.
-- Con impuestos INCLUSIVE no se notaba en la POS porque el frontend ancla el
-- total al precio de catálogo; pero `orders.total`/reportes quedaban igual de
-- mal por debajo.
--
-- CAUSA RAÍZ
-- ──────────
-- La migración `20260509_0004_modifier_per_unit_pricing` (el fix de costo de
-- modifiers POR UNIDAD) reescribió `fn_compute_item_totals` y, sin querer,
-- metió el descuento DENTRO del subtotal:
--
--     new.subtotal := v_line_amount - coalesce(new.discounts, 0);   -- ❌ neto
--     new.tax      := new.subtotal * (v_tax_rate / 100.0);          -- ❌ tax sobre neto
--     new.total    := new.subtotal + new.tax;
--
-- Pero el resto del sistema asume el contrato documentado: `oi.subtotal` es la
-- BASE PRE-DESCUENTO y el descuento viaja aparte en `oi.discounts`. Tanto
-- `calculate_order_totals` (`_total := _subtotal + _tax - _discounts`) como el
-- frontend (`order_pricing_utils.summarizeItemPricing`) VUELVEN a restar el
-- descuento → se cuenta DOS veces.
--
-- FIX
-- ───
-- Restaurar el contrato: `subtotal` = base pre-descuento en AMBOS modos; el
-- impuesto se calcula sobre la base; y el descuento se resta UNA sola vez al
-- armar `new.total`. Se preserva intacto el fix de modifiers por unidad
-- (`v_line_amount = qty * (unit_price + mods)`).
--
-- Diff exacto vs 20260509_0004 (3 líneas):
--   inclusive: `:= v_net_subtotal - discounts`  →  `:= v_net_subtotal`
--   exclusive: `:= v_line_amount  - discounts`  →  `:= v_line_amount`
--   total:     `:= subtotal + tax`              →  `:= subtotal + tax - discounts`
--
-- SEGURIDAD
--   - Items SIN descuento: idénticos a hoy (discounts=0 ⇒ resta 0).
--   - No cambia la fórmula de impuesto inclusive (sigue `subtotal*tax_rate`),
--     así que ningún item inclusive sin descuento cambia de valor.
--   - El backfill toca SOLO órdenes ABIERTAS con descuento. Las pagadas/voided
--     (documentos fiscales/NCF ya emitidos) NO se tocan.
--   - ⚠️ Es CREATE OR REPLACE de una función fiscal. Verificado contra la
--     definición vigente del repo (20260509_0004). Si en prod hubiera una
--     versión divergente, contrastar antes con:
--       SELECT pg_get_functiondef('public.fn_compute_item_totals()'::regprocedure);
-- =============================================================================

begin;

CREATE OR REPLACE FUNCTION public.fn_compute_item_totals()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_line_amount numeric;
  v_mod_total numeric := 0;
  v_extract_rate numeric := 0;
  v_tax_rate numeric := 0;
  v_net_subtotal numeric;
  v_qty numeric;
BEGIN
  v_tax_rate := coalesce(new.tax_rate, 0);
  v_qty := coalesce(new.qty, new.quantity, 1);

  -- Modifiers: costo agregado POR UNIDAD del item (fix 20260509_0004, intacto).
  SELECT coalesce(SUM(qty * price), 0) INTO v_mod_total
  FROM public.order_item_modifiers
  WHERE item_id = new.id;

  v_line_amount := v_qty * (coalesce(new.unit_price, 0) + v_mod_total);

  IF new.tax_mode = 'inclusive' THEN
    v_extract_rate := v_tax_rate;
    IF v_extract_rate > 0 THEN
      v_net_subtotal := v_line_amount / (1 + (v_extract_rate / 100.0));
    ELSE
      v_net_subtotal := v_line_amount;
    END IF;
    -- subtotal = BASE pre-descuento. El descuento NO se mete al subtotal.
    new.subtotal := v_net_subtotal;
    new.tax := new.subtotal * (v_tax_rate / 100.0);
  ELSE
    -- Exclusive: subtotal = base pre-descuento; impuesto sobre la base.
    new.subtotal := v_line_amount;
    new.tax := new.subtotal * (v_tax_rate / 100.0);
  END IF;

  -- El descuento se resta UNA sola vez (viaja aparte en oi.discounts y lo
  -- restan también calculate_order_totals y el frontend).
  new.total := new.subtotal + new.tax - coalesce(new.discounts, 0);

  RETURN new;
END;
$$;

-- ---------------------------------------------------------------------------
-- Backfill: recomputar items con descuento en órdenes ABIERTAS (los únicos
-- afectados — sin descuento, subtotal ya era la base). Pagadas/voided NO se
-- tocan: sus NCF/totales fiscales quedan congelados.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_items int := 0;
  r record;
BEGIN
  -- 1) Touch a los items afectados → dispara el BEFORE UPDATE trigger que
  --    recalcula subtotal/tax/total con la fórmula corregida. El trigger de
  --    sync de tax_lines repuebla las líneas porque subtotal cambia.
  UPDATE public.order_items oi
     SET unit_price = oi.unit_price
    FROM public.orders o
   WHERE oi.order_id = o.id
     AND COALESCE(oi.discounts, 0) > 0
     AND oi.status <> 'void'
     AND o.closed_at IS NULL
     AND COALESCE(o.status_ext::text, '') NOT IN ('paid', 'void');
  GET DIAGNOSTICS v_items = ROW_COUNT;

  -- 2) Recalcular totales de orden y de cada cuenta (check) afectada.
  FOR r IN
    SELECT DISTINCT o.id AS order_id
      FROM public.orders o
      JOIN public.order_items oi ON oi.order_id = o.id
     WHERE COALESCE(oi.discounts, 0) > 0
       AND oi.status <> 'void'
       AND o.closed_at IS NULL
       AND COALESCE(o.status_ext::text, '') NOT IN ('paid', 'void')
  LOOP
    PERFORM public.calculate_order_totals(r.order_id);
  END LOOP;

  FOR r IN
    SELECT DISTINCT oi.check_id AS check_id
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
     WHERE oi.check_id IS NOT NULL
       AND COALESCE(oi.discounts, 0) > 0
       AND oi.status <> 'void'
       AND o.closed_at IS NULL
       AND COALESCE(o.status_ext::text, '') NOT IN ('paid', 'void')
  LOOP
    PERFORM public.calculate_check_totals(r.check_id);
  END LOOP;

  RAISE NOTICE 'Backfill descuento doble: % items recomputados en órdenes abiertas.', v_items;
END $$;

commit;
