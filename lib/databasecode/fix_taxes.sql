-- 1. Agregar columnas para la configuración de impuestos en order_items 
ALTER TABLE public.order_items 
  ADD COLUMN IF NOT EXISTS tax_mode text DEFAULT 'exclusive',
  ADD COLUMN IF NOT EXISTS tax_rate numeric(8,4) DEFAULT 0;

-- 2. Modificar fn_add_item_from_menu para que lea la config del producto y la guarde en la orden
CREATE OR REPLACE FUNCTION public.fn_add_item_from_menu(
  p_order_id uuid,
  p_menu_item_id uuid,
  p_qty numeric default 1,
  p_check_position int default 1,
  p_is_takeout boolean default false,
  p_notes text default null
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name text;
  v_price numeric(12,2);
  v_tax_mode text;
  v_tax_rate numeric(8,4);
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
BEGIN
  v_qty := greatest(coalesce(p_qty, 1), 1);

  SELECT name, price, coalesce(tax_mode, 'exclusive'), coalesce(tax_rate, 0)
    INTO v_name, v_price, v_tax_mode, v_tax_rate
  FROM public.menu_items
  WHERE id = p_menu_item_id
  LIMIT 1;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  INSERT INTO public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, is_takeout, notes, status, added_by,
    tax_mode, tax_rate
  ) VALUES (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, v_qty, v_price, coalesce(p_is_takeout, false), p_notes, 'draft', auth.uid(),
    v_tax_mode, v_tax_rate
  )
  RETURNING id INTO v_item_id;

  PERFORM public.fn_recalc_order_totals(p_order_id);
  RETURN v_item_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.fn_add_item_from_menu(uuid, uuid, numeric, int, boolean, text) TO authenticated;

-- 3. Actualizar el motor de cálculo en el trigger para procesar impuestos Exclusivos e Inclusivos matemáticamente
CREATE OR REPLACE FUNCTION public.fn_compute_item_totals()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE 
  mods_total numeric(12,2) := 0;
  rate numeric(10,6) := 0;
BEGIN
  SELECT coalesce(sum(price*qty),0)
    INTO mods_total
  FROM public.order_item_modifiers
  WHERE item_id = coalesce(new.id, old.id);

  rate := coalesce(new.tax_rate, 0) / 100.0;

  IF new.tax_mode = 'inclusive' THEN
    -- Inclusivo: El precio de lista ya posee el impuesto adentro. 
    new.total := round((new.unit_price * new.qty) + mods_total, 2) - coalesce(new.discounts, 0);
    new.subtotal := round(new.total / (1 + rate), 2);
    new.tax := new.total - new.subtotal;
  ELSE
    -- Exclusivo: Precio base (subtotal), el impuesto se suma por fuera.
    new.subtotal := round((new.unit_price * new.qty) + mods_total, 2);
    new.tax := round((new.subtotal - coalesce(new.discounts, 0)) * rate, 2);
    new.total := new.subtotal - coalesce(new.discounts, 0) + new.tax;
  END IF;

  RETURN new;
END $$;
