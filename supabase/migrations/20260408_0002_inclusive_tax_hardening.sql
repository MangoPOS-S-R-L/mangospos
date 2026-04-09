-- 2026-04-08: Hardening de Impuestos Inclusivos y Soporte para original_tax_rate
BEGIN;

-- 1. Asegurar columnas necesarias en order_items
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS original_tax_rate numeric DEFAULT 0;
COMMENT ON COLUMN public.order_items.original_tax_rate IS 'Tasa de impuestos original del producto para desescalado de precios inclusivos';

-- 2. Asegurar columnas necesarias en taxes
ALTER TABLE public.taxes ADD COLUMN IF NOT EXISTS is_service_fee boolean DEFAULT false;
COMMENT ON COLUMN public.taxes.is_service_fee IS 'Indica si este impuesto es una Propina de Ley / Service Fee';

-- 3. Marcar impuestos que parezcan service fee (10% y nombre Propina)
UPDATE public.taxes SET is_service_fee = true WHERE rate = 10 AND (name ILIKE '%propina%' OR name ILIKE '%service%');

-- 4. Actualizar la función de resolución de impuestos para devolver Full Rate
DROP FUNCTION IF EXISTS "public"."fn_resolve_order_item_tax_profile"("p_product_id" "uuid", "p_order_id" "uuid");
CREATE OR REPLACE FUNCTION "public"."fn_resolve_order_item_tax_profile"("p_product_id" "uuid", "p_order_id" "uuid") 
RETURNS TABLE("tax_mode" "text", "effective_rate" numeric, "full_rate" numeric) 
LANGUAGE "plpgsql" STABLE 
AS $$
DECLARE
  v_origin text;
  v_tax_mode text;
  v_effective_rate numeric := 0;
  v_full_rate numeric := 0;
BEGIN
  -- 1. Obtener el origen del pedido
  SELECT ts.origin INTO v_origin
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;
  
  -- 2. Resolver tax_mode del producto
  SELECT coalesce(mi.tax_mode, 'exclusive') INTO v_tax_mode
  FROM public.menu_items mi
  WHERE mi.id = p_product_id;

  -- 3. Calcular tasas (Full vs Efectiva)
  SELECT 
    coalesce(sum(t.rate), 0)::numeric,
    coalesce(sum(
      CASE 
        WHEN (v_origin = 'dine_in' AND t.apply_on_zone = true) OR
             (v_origin = 'manual' AND t.apply_on_manual = true) OR
             (v_origin = 'quick' AND t.apply_on_quick = true) OR
             (v_origin NOT IN ('dine_in', 'manual', 'quick'))
        THEN t.rate 
        ELSE 0 
      END
    ), 0)::numeric
  INTO v_full_rate, v_effective_rate
  FROM public.menu_item_taxes mit
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE mit.item_id = p_product_id
    AND coalesce(t.is_active, true);

  -- 4. Si no hay impuestos específicos, usar el de por defecto del negocio
  IF v_full_rate = 0 THEN
    SELECT coalesce(bs.default_tax_rate, 0)::numeric INTO v_full_rate
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT join public.business_settings bs ON bs.business_id = ts.business_id
    WHERE o.id = p_order_id;
    
    v_effective_rate := v_full_rate; -- Por defecto aplica todo si no hay reglas
  END IF;

  RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), coalesce(v_effective_rate, 0), coalesce(v_full_rate, 0);
END;
$$;

-- 5. Actualizar fn_add_item_from_menu para usar los nuevos campos
CREATE OR REPLACE FUNCTION "public"."fn_add_item_from_menu"("p_order_id" "uuid", "p_menu_item_id" "uuid", "p_qty" numeric DEFAULT 1, "p_check_position" integer DEFAULT 1, "p_is_takeout" boolean DEFAULT false, "p_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_name text;
  v_price numeric(12,2);
  v_tax_mode text;
  v_effective_rate numeric := 0;
  v_full_rate numeric := 0;
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
begin
  v_qty := greatest(coalesce(p_qty, 1), 0.001);

  select name, price
    into v_name, v_price
  from public.menu_items
  where id = p_menu_item_id
  limit 1;

  if v_name is null then
    raise exception 'MENU_ITEM_NOT_FOUND';
  end if;

  -- Resolver perfil de impuestos incluyendo la tasa full para desescalado
  select profile.tax_mode, profile.effective_rate, profile.full_rate
    into v_tax_mode, v_effective_rate, v_full_rate
  from public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  insert into public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, tax_mode, tax_rate, original_tax_rate, is_takeout, notes, status
  ) values (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, greatest(round(v_qty), 1), v_price, coalesce(v_tax_mode, 'exclusive'),
    coalesce(v_effective_rate, 0), coalesce(v_full_rate, 0), coalesce(p_is_takeout, false), p_notes, 'draft'
  )
  returning id into v_item_id;

  perform public.calculate_order_totals(p_order_id);
  return v_item_id;
end;
$$;

-- 6. RE-IMPLEMENTACIÓN CLAVE: Gatillo de cálculo de totales de item
-- Ahora usa original_tax_rate para desescalar SIEMPRE correctamente.
CREATE OR REPLACE FUNCTION "public"."fn_compute_item_totals"() 
RETURNS trigger 
LANGUAGE plpgsql 
AS $$
DECLARE
  mods_total numeric(12,2) := 0;
  v_line_amount numeric(12,2) := 0;
  v_effective_rate numeric := greatest(coalesce(new.tax_rate, 0), 0);
  v_original_rate numeric := greatest(coalesce(new.original_tax_rate, new.tax_rate, 0), 0);
  v_tax_mode text := coalesce(new.tax_mode, 'exclusive');
  v_net_subtotal numeric(12,2) := 0;
BEGIN
  -- 1. Calcular extras de modificadores
  SELECT coalesce(sum(price * qty), 0) INTO mods_total
  FROM public.order_item_modifiers
  WHERE item_id = COALESCE(new.id, old.id);

  -- 2. Monto bruto de la línea (Cantidad * Precio + Extras)
  v_line_amount := round(
    (coalesce(new.unit_price, 0) * coalesce(new.qty, 1)) + mods_total,
    2
  );

  IF v_tax_mode = 'inclusive' THEN
    -- DESESCALADO: Siempre dividir por la tasa original (ej: 1.28) 
    -- sin importar si el impuesto está activo hoy o no.
    v_net_subtotal := round(v_line_amount / (1 + (v_original_rate / 100.0)), 4);
    
    new.subtotal := round(v_net_subtotal, 2);
    -- TAX: Es la tasa EFECTIVA aplicada al subtotal desescalado.
    new.tax := round(v_net_subtotal * (v_effective_rate / 100.0), 2);
    -- TOTAL: En modo inclusive, el total es el precio bruto (menos descuentos)
    -- Ajustamos el total para que sea consistente con Subtotal + Tax 
    -- si la tasa efectiva es diferente a la original.
    new.total := round(new.subtotal + new.tax - coalesce(new.discounts, 0), 2);
  ELSE
    -- MODO EXCLUSIVE: Comportamiento estándar
    new.subtotal := v_line_amount;
    new.tax := round(new.subtotal * (v_effective_rate / 100.0), 2);
    new.total := round(new.subtotal + new.tax - coalesce(new.discounts, 0), 2);
  END IF;

  RETURN new;
END;
$$;

-- 7. Actualizar calculate_order_totals para evitar doble conteo de Propina
CREATE OR REPLACE FUNCTION "public"."calculate_order_totals"("_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  _subtotal numeric;
  _tax numeric;
  _discounts numeric;
  _service_fee numeric := 0;
  _total numeric;
BEGIN
  -- Sumar totales de items. 
  -- Nota: En este nuevo esquema, TODA la carga fiscal (ITBIS + Propina) 
  -- debe estar en la columna 'tax' del item si son impuestos.
  -- Si deseamos separar 'service_fee' en el footer para visualización, 
  -- debemos extraerla de la tasa.
  
  SELECT 
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0),
    COALESCE(SUM(total), 0)
  INTO _subtotal, _tax, _discounts, _total
  FROM public.order_items
  WHERE order_id = _order_id AND status <> 'void';
  
  -- Sincronizar Service Fee para el footer (solo informativo o si hay lógica legacy)
  -- Aquí asumimos que el 10% ya está en '_tax' si se configuró como impuesto.
  -- Si se prefiere visualizar separado, se podría restar de _tax y mover a service_fee.

  UPDATE public.orders
  SET 
    subtotal = round(_subtotal, 2),
    tax = round(_tax, 2),
    discounts = round(_discounts, 2),
    service_fee = 0, -- Seteamos a 0 para evitar doble conteo si usamos impuestos
    total = round(_total, 2)
  WHERE id = _order_id;
END;
$$;

COMMIT;
