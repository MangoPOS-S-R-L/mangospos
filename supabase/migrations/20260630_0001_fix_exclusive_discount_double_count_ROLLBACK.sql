-- =============================================================================
-- ROLLBACK 20260630_0001 — restaura fn_compute_item_totals a 20260509_0004
-- =============================================================================
-- Revierte SOLO la definición de la función a la versión previa (la que metía
-- el descuento dentro del subtotal). No deshace el backfill de datos: los
-- order_items ya recomputados quedan con subtotal pre-descuento; si se revierte
-- la función, los nuevos touch volverán a netear. Usar solo si el fix forward
-- causa un problema inesperado.
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

commit;
