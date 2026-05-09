-- =============================================================================
-- Modifier price = costo POR UNIDAD del item.
--
-- Bug: cuando un item tiene qty>1, el costo de los modifiers solo se cobraba
-- una vez. Ej: 8 jugos (price=0) + 1 sabor (price=50) → cobraba $50 en vez
-- de $400. La formula vieja en fn_compute_item_totals era:
--
--   v_line_amount = (item.qty * item.unit_price) + mods_total
--
-- Donde mods_total = SUM(modifier.qty * modifier.price) se sumaba como
-- absoluto. Si modifier.qty=1, el sabor entraba 1 vez sin importar
-- cuantos items habia.
--
-- Fix: tratar el costo de modifiers como POR UNIDAD del item parent. La
-- semantica nueva es:
--   - modifier.qty representa "cuantos modifiers de este tipo por cada
--     unidad del item". Default 1.
--   - modifier.price representa "costo de un modifier".
--   - El total agregado es: item.qty * SUM(modifier.qty * modifier.price).
--
--   v_line_amount = item.qty * (item.unit_price + mods_total)
--
-- Casos:
--   - 1 jugo $0 + sabor $50  → 1 * (0 + 50)        = $50    ✓
--   - 8 jugos $0 + sabor $50 → 8 * (0 + 50)        = $400   ✓ (antes: $50)
--   - 1 burger $200 + queso x2 ($20) → 1 * (200+40) = $240  ✓
--   - 3 burgers + queso x2 c/u → 3 * (200+40)      = $720   ✓ (antes: $640)
--
-- Compat: codigo de UI ya usa modifier.qty=1 por default, asi que ningun
-- flujo existente queda mal con esta interpretacion. Items con qty=1 y
-- modifiers tienen el mismo total que antes (qty * (unit + mods) =
-- 1 * (unit + mods) = unit + mods).
--
-- Backfill: re-compute todos los order_items en orders abiertas que tengan
-- qty>1 con modifiers (los unicos que cambian de valor). Pagadas/voided
-- se respetan.
-- =============================================================================

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

  -- Modifiers: costo agregado por UNIDAD del item.
  SELECT coalesce(SUM(qty * price), 0) INTO v_mod_total
  FROM public.order_item_modifiers
  WHERE item_id = new.id;

  -- Multiplicar (unit_price + mods) por qty del item. Antes mods se sumaba
  -- absoluto y solo se cobraba 1 vez sin importar qty.
  v_line_amount := v_qty * (coalesce(new.unit_price, 0) + v_mod_total);

  IF new.tax_mode = 'inclusive' THEN
    v_extract_rate := v_tax_rate;
    IF v_extract_rate > 0 THEN
      v_net_subtotal := v_line_amount / (1 + (v_extract_rate / 100.0));
    ELSE
      v_net_subtotal := v_line_amount;
    END IF;
    new.subtotal := v_net_subtotal - coalesce(new.discounts, 0);
    new.tax := new.subtotal * (v_tax_rate / 100.0);
  ELSE
    new.subtotal := v_line_amount - coalesce(new.discounts, 0);
    new.tax := new.subtotal * (v_tax_rate / 100.0);
  END IF;

  new.total := new.subtotal + new.tax;

  RETURN new;
END;
$$;

-- ---------------------------------------------------------------------------
-- Backfill: re-compute order_items en orders abiertas con modifiers Y qty>1.
-- Items con qty=1 no cambian de valor, no necesitan touch.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_affected int := 0;
BEGIN
  WITH items_to_touch AS (
    SELECT DISTINCT oi.id
    FROM public.order_items oi
    JOIN public.order_item_modifiers oim ON oim.item_id = oi.id
    JOIN public.orders o ON o.id = oi.order_id
    WHERE o.closed_at IS NULL
      AND COALESCE(o.status_ext::text, '') NOT IN ('paid', 'void')
      AND oi.status <> 'void'
      AND COALESCE(oi.qty, oi.quantity, 1) > 1
  )
  UPDATE public.order_items oi
    SET unit_price = oi.unit_price
  FROM items_to_touch t
  WHERE oi.id = t.id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RAISE NOTICE 'Backfill: % order_items recalculados con la nueva formula '
               'por-unidad (solo qty>1 con modifiers).',
               v_affected;
END;
$$;
