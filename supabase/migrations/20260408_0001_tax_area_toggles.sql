-- Agrega columnas para controlar en qué secciones se aplica cada impuesto.
ALTER TABLE public.taxes ADD COLUMN IF NOT EXISTS apply_on_zone boolean NOT NULL DEFAULT true;
ALTER TABLE public.taxes ADD COLUMN IF NOT EXISTS apply_on_manual boolean NOT NULL DEFAULT true;
ALTER TABLE public.taxes ADD COLUMN IF NOT EXISTS apply_on_quick boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.taxes.apply_on_zone IS 'Aplicar este impuesto en ventas por zona (mesas / dine-in)';
COMMENT ON COLUMN public.taxes.apply_on_manual IS 'Aplicar este impuesto en ventas manuales (mostrador / walk-in)';
COMMENT ON COLUMN public.taxes.apply_on_quick IS 'Aplicar este impuesto en venta rápida (quick sale)';

-- Columna para guardar la tasa original completa del producto (antes de filtrar por origin).
-- Permite al trigger extraer la base correcta en productos inclusivos.
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS original_tax_rate numeric DEFAULT NULL;

-- Corregir fn_compute_item_totals: en productos inclusivos, extraer la base
-- con la tasa ORIGINAL y aplicar solo la tasa efectiva (filtrada por origin).
-- Así al desactivar un impuesto el total BAJA en vez de absorber el tax en el subtotal.
CREATE OR REPLACE FUNCTION "public"."fn_compute_item_totals"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  mods_total numeric(12,2) := 0;
  v_line_amount numeric(12,2) := 0;
  v_tax_rate numeric := greatest(coalesce(new.tax_rate, 0), 0);
  v_tax_mode text := coalesce(new.tax_mode, 'exclusive');
  v_net_subtotal numeric(12,2) := 0;
  v_extract_rate numeric := 0;
begin
  select coalesce(sum(price*qty),0)
    into mods_total
  from public.order_item_modifiers
  where item_id = coalesce(new.id, old.id);

  v_line_amount := round(
    (coalesce(new.unit_price, 0) * coalesce(new.qty, new.quantity, 1)) +
    mods_total,
    2
  );

  if v_tax_mode = 'inclusive' then
    -- Usar original_tax_rate (tasa completa del producto) para extraer la base real.
    -- Si no está seteada, usar tax_rate (compatibilidad con items viejos).
    v_extract_rate := greatest(coalesce(new.original_tax_rate, v_tax_rate), 0);

    if v_extract_rate > 0 then
      v_net_subtotal := round(v_line_amount / (1 + (v_extract_rate / 100.0)), 2);
    else
      v_net_subtotal := v_line_amount;
    end if;

    new.subtotal := v_net_subtotal;

    if v_tax_rate > 0 then
      new.tax := round(v_net_subtotal * (v_tax_rate / 100.0), 2);
    else
      new.tax := 0;
    end if;

    -- Total = base + impuesto aplicable (NO el precio del menú).
    -- Cuando original_tax_rate = tax_rate, total = line_amount (sin cambio).
    new.total := round(new.subtotal + new.tax - coalesce(new.discounts, 0), 2);
  else
    new.subtotal := v_line_amount;
    new.tax := round(new.subtotal * (v_tax_rate / 100.0), 2);
    new.total := round(
      new.subtotal - coalesce(new.discounts,0) + coalesce(new.tax,0),
      2
    );
  end if;
  return new;
end $$;

-- Actualizar fn_add_item_from_menu para guardar original_tax_rate (tasa completa)
-- además de tax_rate (tasa filtrada por origin).
CREATE OR REPLACE FUNCTION "public"."fn_add_item_from_menu"("p_order_id" "uuid", "p_menu_item_id" "uuid", "p_qty" numeric DEFAULT 1, "p_check_position" integer DEFAULT 1, "p_is_takeout" boolean DEFAULT false, "p_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_name text;
  v_price numeric(12,2);
  v_tax_mode text;
  v_tax_rate numeric := 0;
  v_full_tax_rate numeric := 0;
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
begin
  v_qty := greatest(coalesce(p_qty, 1), 1);

  select name, price
    into v_name, v_price
  from public.menu_items
  where id = p_menu_item_id
  limit 1;

  if v_name is null then
    raise exception 'MENU_ITEM_NOT_FOUND';
  end if;

  -- Tasa filtrada por origin (la que se aplica)
  select profile.tax_mode, profile.tax_rate
    into v_tax_mode, v_tax_rate
  from public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

  -- Tasa completa (todos los impuestos activos del negocio, sin filtrar por origin)
  select coalesce(sum(t.rate), 0)::numeric
    into v_full_tax_rate
  from public.taxes t
  where t.business_id = (
    select ts.business_id from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    where o.id = p_order_id limit 1
  )
    and coalesce(t.is_active, true);

  -- Si no hay impuestos configurados, la tasa completa = la filtrada
  if v_full_tax_rate = 0 then
    v_full_tax_rate := v_tax_rate;
  end if;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  insert into public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, tax_mode, tax_rate, original_tax_rate,
    is_takeout, notes, status
  ) values (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, v_qty, v_price, coalesce(v_tax_mode, 'exclusive'),
    coalesce(v_tax_rate, 0), v_full_tax_rate,
    coalesce(p_is_takeout, false), p_notes, 'draft'
  )
  returning id into v_item_id;

  perform public.fn_recalc_order_totals(p_order_id);
  return v_item_id;
end;
$$;

-- Actualizar la función para filtrar impuestos por origen al agregar items
DROP FUNCTION IF EXISTS public.fn_resolve_order_item_tax_profile(uuid, uuid);
CREATE OR REPLACE FUNCTION "public"."fn_resolve_order_item_tax_profile"("p_product_id" "uuid", "p_order_id" "uuid") 
RETURNS TABLE("tax_mode" "text", "tax_rate" numeric) 
LANGUAGE "plpgsql" STABLE 
AS $$
DECLARE
  v_origin text;
  v_tax_mode text;
  v_tax_rate numeric;
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

  -- 3. Sumar TODOS los impuestos activos del negocio que apliquen al origen.
  --    Los impuestos son a nivel de negocio, no de producto.
  SELECT coalesce(sum(t.rate), 0)::numeric INTO v_tax_rate
  FROM public.taxes t
  WHERE t.business_id = (
    SELECT ts.business_id FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE o.id = p_order_id
    LIMIT 1
  )
    AND coalesce(t.is_active, true)
    AND (
      (v_origin IN ('dine_in', 'table', 'zone', 'table_order') AND t.apply_on_zone = true) OR
      (v_origin IN ('manual', 'manual_order') AND t.apply_on_manual = true) OR
      (v_origin IN ('quick', 'quick_sale') AND t.apply_on_quick = true) OR
      (v_origin = 'delivery' AND t.apply_on_delivery = true) OR
      (v_origin IS NULL OR v_origin NOT IN ('dine_in','table','zone','table_order','manual','manual_order','quick','quick_sale','delivery'))
    );

  -- 4. Si no hay impuestos configurados, usar el default del negocio.
  IF v_tax_rate = 0 AND NOT EXISTS (
    SELECT 1 FROM public.taxes t2
    WHERE t2.business_id = (
      SELECT ts2.business_id FROM public.orders o2
      JOIN public.table_sessions ts2 ON ts2.id = o2.session_id
      WHERE o2.id = p_order_id LIMIT 1
    ) AND coalesce(t2.is_active, true)
  ) THEN
    SELECT coalesce(bs.default_tax_rate, 0)::numeric INTO v_tax_rate
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT JOIN public.business_settings bs ON bs.business_id = ts.business_id
    WHERE o.id = p_order_id;
  END IF;

  RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), coalesce(v_tax_rate, 0);
END;
$$;

-- Actualizar calculo de totales para respetar area-specific service fee
CREATE OR REPLACE FUNCTION "public"."calculate_order_totals"("_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  _subtotal numeric;
  _tax numeric;
  _discounts numeric;
  _service_fee numeric := 0;
  _total numeric;
  _sf_enabled boolean;
  _sf_rate numeric;
  _origin text;
  _sf_on_zone boolean;
  _sf_on_manual boolean;
  _sf_on_quick boolean;
  _apply_sf boolean := false;
BEGIN
  -- 1. Sumar totales de items
  SELECT 
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE order_id = _order_id;
  
  -- 2. Obtener configuracion y origen
  SELECT 
    COALESCE(bs.service_fee_enabled, false), 
    COALESCE(bs.service_fee_rate, 10),
    ts.origin::text,
    COALESCE(bs.service_fee_on_zone, true),
    COALESCE(bs.service_fee_on_manual, true),
    COALESCE(bs.service_fee_on_quick, false)
  INTO _sf_enabled, _sf_rate, _origin, _sf_on_zone, _sf_on_manual, _sf_on_quick
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  JOIN public.business_settings bs ON ts.business_id = bs.business_id
  WHERE o.id = _order_id;

  -- 3. Determinar si aplica SF para este origen
  IF _sf_enabled THEN
    IF _origin = 'dine_in' AND _sf_on_zone THEN _apply_sf := true;
    ELSIF _origin = 'manual' AND _sf_on_manual THEN _apply_sf := true;
    ELSIF _origin = 'quick' AND _sf_on_quick THEN _apply_sf := true;
    ELSIF _origin NOT IN ('dine_in', 'manual', 'quick') THEN _apply_sf := true;
    END IF;
  END IF;

  -- 4. Calcular service fee
  IF _apply_sf THEN
    SELECT COALESCE(SUM(subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items
    WHERE order_id = _order_id AND is_takeout = false;
  END IF;
  
  _total := _subtotal + _tax + _service_fee - _discounts;
  
  -- 5. Actualizar la orden
  UPDATE public.orders
  SET 
    subtotal = _subtotal,
    tax = _tax,
    discounts = _discounts,
    service_fee = ROUND(_service_fee, 2),
    total = ROUND(_total, 2)
  WHERE id = _order_id;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."calculate_check_totals"("_check_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  _subtotal numeric;
  _tax numeric;
  _discounts numeric;
  _service_fee numeric := 0;
  _total numeric;
  _sf_enabled boolean;
  _sf_rate numeric;
  _origin text;
  _sf_on_zone boolean;
  _sf_on_manual boolean;
  _sf_on_quick boolean;
  _apply_sf boolean := false;
BEGIN
  -- 1. Sumar totales del check
  SELECT 
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE check_id = _check_id;

  -- 2. Obtener configuracion y origen
  SELECT 
    COALESCE(bs.service_fee_enabled, false), 
    COALESCE(bs.service_fee_rate, 10),
    ts.origin::text,
    COALESCE(bs.service_fee_on_zone, true),
    COALESCE(bs.service_fee_on_manual, true),
    COALESCE(bs.service_fee_on_quick, false)
  INTO _sf_enabled, _sf_rate, _origin, _sf_on_zone, _sf_on_manual, _sf_on_quick
  FROM public.order_checks ch
  JOIN public.orders o ON ch.order_id = o.id
  JOIN public.table_sessions ts ON o.session_id = ts.id
  JOIN public.business_settings bs ON ts.business_id = bs.business_id
  WHERE ch.id = _check_id;

  -- 3. Determinar si aplica SF para este origen
  IF _sf_enabled THEN
    IF _origin = 'dine_in' AND _sf_on_zone THEN _apply_sf := true;
    ELSIF _origin = 'manual' AND _sf_on_manual THEN _apply_sf := true;
    ELSIF _origin = 'quick' AND _sf_on_quick THEN _apply_sf := true;
    ELSIF _origin NOT IN ('dine_in', 'manual', 'quick') THEN _apply_sf := true;
    END IF;
  END IF;

  -- 4. Calcular service fee para el check
  IF _apply_sf THEN
    SELECT COALESCE(SUM(subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items
    WHERE check_id = _check_id AND is_takeout = false;
  END IF;

  _total := _subtotal + _tax + _service_fee - _discounts;

  -- 5. Actualizar el check
  UPDATE public.order_checks
  SET 
    subtotal = _subtotal,
    tax = _tax,
    discounts = _discounts,
    service_fee = ROUND(_service_fee, 2),
    total = ROUND(_total, 2)
  WHERE id = _check_id;
END;
$$;

-- Función para actualizar el tax_rate de un item de forma segura (bypasa RLS)
CREATE OR REPLACE FUNCTION "public"."fn_update_item_tax_rate"(
  "p_item_id" "uuid",
  "p_tax_rate" numeric,
  "p_original_tax_rate" numeric DEFAULT NULL
) RETURNS void
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
BEGIN
  UPDATE public.order_items
  SET
    tax_rate = coalesce(p_tax_rate, tax_rate),
    original_tax_rate = coalesce(p_original_tax_rate, original_tax_rate)
  WHERE id = p_item_id;
END;
$$;

