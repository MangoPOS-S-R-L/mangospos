-- Captured from production on 2026-04-28 (PRD 2 F2.2 pre-step).
-- Source: SELECT pg_get_functiondef('public.fn_compute_item_totals'::regproc);
-- Use: rollback target if PRD 2 modifications break this function.

CREATE OR REPLACE FUNCTION public.fn_compute_item_totals()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  mods_total numeric := 0;
  v_line_amount numeric := 0;
  v_tax_rate numeric := greatest(coalesce(new.tax_rate, 0), 0);
  v_tax_mode text := coalesce(new.tax_mode, 'exclusive');
  v_net_subtotal numeric := 0;
  v_extract_rate numeric := 0;
BEGIN
  -- 1. Sumar modificadores con precisión total
  SELECT coalesce(sum(price * qty), 0) INTO mods_total
  FROM public.order_item_modifiers
  WHERE item_id = coalesce(new.id, old.id);

  v_line_amount := (coalesce(new.unit_price, 0) * coalesce(new.qty, new.quantity, 1)) + mods_total;

  IF v_tax_mode = 'inclusive' THEN
    v_extract_rate := greatest(coalesce(new.original_tax_rate, v_tax_rate), 0);

    IF v_extract_rate > 0 THEN
      -- Calculamos subtotal sin redondear a 2 (mantenemos los decimales para sumar exacto en la orden)
      v_net_subtotal := v_line_amount / (1 + (v_extract_rate / 100.0));
    ELSE
      v_net_subtotal := v_line_amount;
    END IF;

    new.subtotal := v_net_subtotal;

    IF v_tax_rate > 0 THEN
      new.tax := v_net_subtotal * (v_tax_rate / 100.0);
    ELSE
      new.tax := 0;
    END IF;

    -- Total del ítem
    new.total := new.subtotal + new.tax - coalesce(new.discounts, 0);
  ELSE
    -- Modo Exclusivo
    new.subtotal := v_line_amount;
    new.tax := new.subtotal * (v_tax_rate / 100.0);
    new.total := new.subtotal - coalesce(new.discounts, 0) + coalesce(new.tax, 0);
  END IF;

  RETURN new;
END;
$function$;
