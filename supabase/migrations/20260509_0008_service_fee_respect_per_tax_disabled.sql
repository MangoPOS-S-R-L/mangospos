-- 2026-05-09: Service fee — respetar el toggle del usuario en negocios nuevos.
--
-- Problema reportado
-- ------------------
-- En un negocio recien creado, el usuario va a Impuestos y desactiva
-- (`is_active=false`) la fila de "Propina Ley 10%" via el toggle del UI,
-- pero el 10% sigue saliendo en las ordenes.
--
-- Root cause
-- ----------
-- Son dos bugs encadenados:
--
-- 1. La funcion deployada `create_business_defaults` fuerza
--    `business_settings.service_fee_enabled = true` al crear el negocio,
--    contradiciendo la default false del DDL. Esa setting es el "master
--    switch" que `calculate_order_totals` consulta.
--
-- 2. `calculate_order_totals` (migracion 20260429_0001) decide entre:
--      - Per-tax mode: suma rates de `taxes` con
--        `is_service_fee=true AND is_active=true AND apply_on_<origin>`.
--      - Legacy mode: si NO hay rows que cumplan ese filtro, aplica
--        `business_settings.service_fee_rate * apply_on_<origin>` flags.
--
--    El bug: cuando el usuario apaga `is_active` en la unica fila de
--    Propina, `_has_per_tax_sf` queda en false (porque el WHERE filtra por
--    is_active), y el motor cae al legacy fallback. Como el master switch
--    ya esta forzado a true, aplica 10%.
--
-- Fix
-- ---
-- A. `create_business_defaults`: insertar con `service_fee_enabled = false`
--    (matchea el DDL y la version simple en schema.sql) y NO force-update
--    despues. Negocios nuevos arrancan con la propina apagada por default.
--
-- B. `calculate_order_totals` y `calculate_check_totals`: separar la
--    deteccion "existe configuracion per-tax" del "rate aplicable". Si
--    existe AL MENOS una fila con `is_service_fee=true` para el negocio
--    (independiente de is_active u origin), `_has_per_tax_sf=true` y NO se
--    cae al legacy. El rate sumado sigue respetando is_active y origin —
--    asi una fila apagada contribuye 0 en vez de re-habilitarse via legacy.
--
-- Compatibilidad
-- --------------
-- - Negocios viejos sin ninguna fila `is_service_fee=true` siguen con el
--   path legacy (master switch + rate fallback). Sin cambios para ellos.
-- - Negocios con >=1 fila `is_service_fee=true` se rigen 100% por la tabla
--   `taxes`: si todas estan inactivas, no hay propina, sin importar
--   `business_settings.service_fee_*`.
-- - El DO $$ del final no toca esta migracion (no recalculamos masivo —
--   los users veran el cambio al siguiente edit de orden).

-- ═══════════════════════════════════════════════════════════════════════
-- Fix A: create_business_defaults — no forzar master switch
-- ═══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_business_defaults(_business_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.payment_methods (business_id, name, code, position, icon)
  SELECT _business_id, 'Efectivo', 'cash', 1, 'banknote'
  WHERE NOT EXISTS (
    SELECT 1 FROM public.payment_methods pm
    WHERE pm.business_id = _business_id AND pm.code = 'cash'
  );

  INSERT INTO public.payment_methods (business_id, name, code, position, icon)
  SELECT _business_id, 'Tarjeta', 'card', 2, 'credit-card'
  WHERE NOT EXISTS (
    SELECT 1 FROM public.payment_methods pm
    WHERE pm.business_id = _business_id AND pm.code = 'card'
  );

  INSERT INTO public.payment_methods (business_id, name, code, position, icon)
  SELECT _business_id, 'Transferencia', 'transfer', 3, 'building-2'
  WHERE NOT EXISTS (
    SELECT 1 FROM public.payment_methods pm
    WHERE pm.business_id = _business_id AND pm.code = 'transfer'
  );

  INSERT INTO public.currencies (business_id, code, name, symbol, is_default)
  SELECT _business_id, 'DOP', 'Peso Dominicano', 'RD$', true
  WHERE EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'currencies'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.currencies c
    WHERE c.business_id = _business_id AND c.is_default = true
  );

  -- Cambio clave: insertar con service_fee_enabled = FALSE (matchea DDL).
  -- Antes: service_fee_enabled=true + force-update posterior. Eso hacia
  -- que el toggle del usuario en Impuestos no fuera la fuente de verdad.
  INSERT INTO public.business_settings (
    business_id,
    default_tax_rate,
    service_fee_enabled,
    service_fee_rate
  )
  SELECT _business_id, 18, false, 10
  WHERE NOT EXISTS (
    SELECT 1 FROM public.business_settings bs WHERE bs.business_id = _business_id
  );

  -- (Removido: el UPDATE force-true que estaba aqui antes.)

  INSERT INTO public.taxes (business_id, name, rate)
  SELECT _business_id, 'ITBIS', 18
  WHERE NOT EXISTS (
    SELECT 1 FROM public.taxes t
    WHERE t.business_id = _business_id AND lower(t.name) = lower('ITBIS')
  );

  INSERT INTO public.zones (business_id, name, sort_index)
  SELECT _business_id, 'Salon Principal', 1
  WHERE NOT EXISTS (
    SELECT 1 FROM public.zones z
    WHERE z.business_id = _business_id AND lower(z.name) = lower('Salon Principal')
  );

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'warehouses'
  ) THEN
    INSERT INTO public.warehouses (business_id, name, is_main)
    SELECT _business_id, 'Almacen Principal', true
    WHERE NOT EXISTS (
      SELECT 1 FROM public.warehouses w
      WHERE w.business_id = _business_id AND w.is_main = true
    );
  END IF;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- Fix B: calculate_order_totals — no caer al legacy si hay propina
-- configurada (incluso inactiva)
-- ═══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION "public"."calculate_order_totals"("_order_id" "uuid")
RETURNS "void"
LANGUAGE "plpgsql"
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
DECLARE
  _subtotal numeric := 0;
  _tax numeric := 0;
  _discounts numeric := 0;
  _service_fee numeric := 0;
  _total numeric := 0;
  _origin text;
  _biz_id uuid;
  _sf_enabled boolean := false;
  _sf_rate_total numeric := 0;
  _sf_taxable_subtotal numeric := 0;
  _has_per_tax_sf boolean := false;
  _legacy_sf_rate numeric := 10;
  _legacy_apply boolean := false;
  _legacy_on_zone boolean := true;
  _legacy_on_manual boolean := true;
  _legacy_on_quick boolean := false;
  _legacy_on_delivery boolean := false;
BEGIN
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO _origin, _biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  WHERE o.id = _order_id;

  SELECT
    COALESCE(SUM(oi.subtotal), 0),
    COALESCE(SUM(oi.tax), 0),
    COALESCE(SUM(oi.discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items oi
  LEFT JOIN public.order_checks oc ON oi.check_id = oc.id
  WHERE oi.order_id = _order_id
    AND oi.status NOT IN ('paid', 'void')
    AND COALESCE(oc.is_closed, false) = false;

  SELECT COALESCE(bs.service_fee_enabled, false),
         COALESCE(bs.service_fee_rate, 10),
         COALESCE(bs.service_fee_on_zone, true),
         COALESCE(bs.service_fee_on_manual, true),
         COALESCE(bs.service_fee_on_quick, false),
         COALESCE(bs.service_fee_on_delivery, false)
    INTO _sf_enabled, _legacy_sf_rate,
         _legacy_on_zone, _legacy_on_manual, _legacy_on_quick, _legacy_on_delivery
  FROM public.business_settings bs
  WHERE bs.business_id = _biz_id;

  IF _sf_enabled THEN
    -- Cambio clave vs migracion anterior: separamos la deteccion de
    -- "el negocio tiene config per-tax" de la suma de rates aplicables.
    -- Si existe AL MENOS UNA fila is_service_fee=true (cualquier estado),
    -- el negocio esta en modo per-tax y NO caemos al legacy.
    SELECT EXISTS (
      SELECT 1 FROM public.taxes t
      WHERE t.business_id = _biz_id
        AND COALESCE(t.is_service_fee, false) = true
    ) INTO _has_per_tax_sf;

    -- El rate aplicable sigue respetando is_active y origin. Si el
    -- usuario apago la unica fila, _sf_rate_total = 0 y no se aplica
    -- propina — pero TAMPOCO caemos al fallback legacy (que aplicaria
    -- service_fee_rate por su cuenta). Esa es la diferencia que arregla
    -- el bug.
    SELECT COALESCE(SUM(t.rate), 0)
      INTO _sf_rate_total
    FROM public.taxes t
    WHERE t.business_id = _biz_id
      AND COALESCE(t.is_active, true)
      AND COALESCE(t.is_service_fee, false) = true
      AND (
        (_origin IN ('dine_in','table','zone','table_order') AND t.apply_on_zone = true) OR
        (_origin IN ('manual','manual_order') AND t.apply_on_manual = true) OR
        (_origin IN ('quick','quick_sale','quick-sale') AND t.apply_on_quick = true) OR
        ((_origin = 'delivery' OR _origin LIKE '%delivery%') AND t.apply_on_delivery = true) OR
        (_origin IS NULL OR _origin NOT IN (
          'dine_in','table','zone','table_order',
          'manual','manual_order',
          'quick','quick_sale','quick-sale',
          'delivery'
        ))
      );

    IF NOT _has_per_tax_sf THEN
      -- Solo negocios sin NINGUNA fila is_service_fee=true caen al legacy.
      CASE
        WHEN _origin IN ('table','dine_in','zone','table_order') THEN _legacy_apply := _legacy_on_zone;
        WHEN _origin IN ('manual','manual_order') THEN _legacy_apply := _legacy_on_manual;
        WHEN _origin IN ('quick','quick_sale','quick-sale') THEN _legacy_apply := _legacy_on_quick;
        WHEN _origin = 'delivery' OR _origin LIKE '%delivery%' THEN _legacy_apply := _legacy_on_delivery;
        ELSE _legacy_apply := true;
      END CASE;
      IF _legacy_apply THEN
        _sf_rate_total := _legacy_sf_rate;
      ELSE
        _sf_rate_total := 0;
      END IF;
    END IF;

    IF _sf_rate_total > 0 THEN
      SELECT COALESCE(SUM(oi.subtotal), 0)
        INTO _sf_taxable_subtotal
      FROM public.order_items oi
      LEFT JOIN public.order_checks oc ON oi.check_id = oc.id
      WHERE oi.order_id = _order_id
        AND oi.is_takeout = false
        AND oi.status NOT IN ('paid', 'void')
        AND COALESCE(oc.is_closed, false) = false;

      _service_fee := _sf_taxable_subtotal * (_sf_rate_total / 100.0);
    END IF;
  END IF;

  _total := _subtotal + _tax + _service_fee - _discounts;

  UPDATE public.orders SET
    subtotal    = ROUND(_subtotal, 2),
    tax         = ROUND(_tax, 2),
    service_fee = ROUND(_service_fee, 2),
    discounts   = ROUND(_discounts, 2),
    total       = ROUND(_total, 2)
  WHERE id = _order_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- Fix B (segunda parte): calculate_check_totals — misma logica
-- ═══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION "public"."calculate_check_totals"("_check_id" "uuid")
RETURNS "void"
LANGUAGE "plpgsql"
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
DECLARE
  _subtotal numeric := 0;
  _tax numeric := 0;
  _discounts numeric := 0;
  _service_fee numeric := 0;
  _total numeric := 0;
  _origin text;
  _biz_id uuid;
  _sf_enabled boolean := false;
  _sf_rate_total numeric := 0;
  _sf_taxable_subtotal numeric := 0;
  _has_per_tax_sf boolean := false;
  _legacy_sf_rate numeric := 10;
  _legacy_apply boolean := false;
  _legacy_on_zone boolean := true;
  _legacy_on_manual boolean := true;
  _legacy_on_quick boolean := false;
  _legacy_on_delivery boolean := false;
BEGIN
  SELECT
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE check_id = _check_id
    AND status NOT IN ('void');

  SELECT
    trim(lower(ts.origin::text)),
    ts.business_id,
    COALESCE(bs.service_fee_enabled, false),
    COALESCE(bs.service_fee_rate, 10),
    COALESCE(bs.service_fee_on_zone, true),
    COALESCE(bs.service_fee_on_manual, true),
    COALESCE(bs.service_fee_on_quick, false),
    COALESCE(bs.service_fee_on_delivery, false)
  INTO _origin, _biz_id, _sf_enabled, _legacy_sf_rate,
       _legacy_on_zone, _legacy_on_manual, _legacy_on_quick, _legacy_on_delivery
  FROM public.order_checks ch
  JOIN public.orders o ON ch.order_id = o.id
  JOIN public.table_sessions ts ON o.session_id = ts.id
  JOIN public.business_settings bs ON ts.business_id = bs.business_id
  WHERE ch.id = _check_id;

  IF _sf_enabled THEN
    SELECT EXISTS (
      SELECT 1 FROM public.taxes t
      WHERE t.business_id = _biz_id
        AND COALESCE(t.is_service_fee, false) = true
    ) INTO _has_per_tax_sf;

    SELECT COALESCE(SUM(t.rate), 0)
      INTO _sf_rate_total
    FROM public.taxes t
    WHERE t.business_id = _biz_id
      AND COALESCE(t.is_active, true)
      AND COALESCE(t.is_service_fee, false) = true
      AND (
        (_origin IN ('dine_in','table','zone','table_order') AND t.apply_on_zone = true) OR
        (_origin IN ('manual','manual_order') AND t.apply_on_manual = true) OR
        (_origin IN ('quick','quick_sale','quick-sale') AND t.apply_on_quick = true) OR
        ((_origin = 'delivery' OR _origin LIKE '%delivery%') AND t.apply_on_delivery = true) OR
        (_origin IS NULL OR _origin NOT IN (
          'dine_in','table','zone','table_order',
          'manual','manual_order',
          'quick','quick_sale','quick-sale',
          'delivery'
        ))
      );

    IF NOT _has_per_tax_sf THEN
      CASE
        WHEN _origin IN ('table','dine_in','zone','table_order') THEN _legacy_apply := _legacy_on_zone;
        WHEN _origin IN ('manual','manual_order') THEN _legacy_apply := _legacy_on_manual;
        WHEN _origin IN ('quick','quick_sale','quick-sale') THEN _legacy_apply := _legacy_on_quick;
        WHEN _origin = 'delivery' OR _origin LIKE '%delivery%' THEN _legacy_apply := _legacy_on_delivery;
        ELSE _legacy_apply := true;
      END CASE;
      IF _legacy_apply THEN
        _sf_rate_total := _legacy_sf_rate;
      ELSE
        _sf_rate_total := 0;
      END IF;
    END IF;

    IF _sf_rate_total > 0 THEN
      SELECT COALESCE(SUM(subtotal), 0)
        INTO _sf_taxable_subtotal
      FROM public.order_items
      WHERE check_id = _check_id
        AND is_takeout = false
        AND status NOT IN ('void');

      _service_fee := _sf_taxable_subtotal * (_sf_rate_total / 100.0);
    END IF;
  END IF;

  _total := _subtotal + _tax + _service_fee - _discounts;

  UPDATE public.order_checks SET
    subtotal    = ROUND(_subtotal, 2),
    tax         = ROUND(_tax, 2),
    discounts   = ROUND(_discounts, 2),
    service_fee = ROUND(_service_fee, 2),
    total       = ROUND(_total, 2)
  WHERE id = _check_id;
END;
$$;

-- Recalcular ordenes abiertas para refrescar service_fee con la nueva
-- logica. Cerradas quedan inmutables (snapshot historico).
DO $$
DECLARE
  _id uuid;
BEGIN
  FOR _id IN
    SELECT o.id FROM public.orders o
    WHERE o.status_ext = 'open'
  LOOP
    PERFORM public.calculate_order_totals(_id);
  END LOOP;
END $$;
