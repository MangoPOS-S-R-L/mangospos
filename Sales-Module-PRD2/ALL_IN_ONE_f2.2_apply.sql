-- =============================================================================
-- File:        ALL_IN_ONE_f2.2_apply.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2 — apply
-- Author:      Cristian
-- Date:        2026-04-28
--
-- Purpose:
--   Consolida en UN SOLO ARCHIVO los 8 bloques que aplican F2.2 a Supabase
--   (en el orden correcto). Generado a partir de los archivos individuales
--   `01_*` a `07_*` + `migrations/01_*`. Los archivos individuales NO se
--   borran — son la fuente de verdad para revisión y rollback granular.
--
-- Cómo correrlo:
--   - OPCIÓN A (recomendada para staging): pegá TODO el contenido de este
--     archivo en el SQL editor de Supabase y ejecutalo de una vez. Está
--     envuelto en BEGIN; ... COMMIT; así que si cualquier bloque falla,
--     toda la transacción se revierte automáticamente.
--
--   - OPCIÓN B (recomendada para producción): correr bloque por bloque.
--     Cada bloque está delimitado por una línea `-- ===== BLOQUE N =====`.
--     Pegá un bloque, ejecutalo, verificá el output, y recién pegá el
--     siguiente. Para esta opción IGNORAR los `BEGIN;` y `COMMIT;` del
--     wrapper externo y dejar que cada bloque sea su propia transacción.
--
-- Después de aplicar:
--   Correr `99_f2.2_parity_test.sql` para validar.
--
-- Rollback:
--   Si algo falla en STAGING en modo A, no hay que hacer nada (la
--   transacción se revirtió sola). Si hay que revertir DESPUÉS del COMMIT,
--   ver `rollback/` para los SQL inversos ordenados.
-- =============================================================================

BEGIN;


-- ==========================================================================
-- BLOQUE 1 / 8 — Crear tabla order_item_tax_lines (PRD §6.1)
-- Source: 01_f2.2_create_order_item_tax_lines.sql
-- ==========================================================================

-- =============================================================================
-- File:        01_f2.2_create_order_item_tax_lines.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes
-- Rollback:    rollback/01_drop_order_item_tax_lines.sql
--
-- Purpose:
--   Crea `order_item_tax_lines`: tabla de auditoría detallada por impuesto
--   y por línea de venta. Cada fila es un snapshot inmutable del impuesto
--   aplicado al momento de la venta (nombre y tasa al momento, no referencia
--   viva). Sirve como fuente de verdad para reportes fiscales del PRD 3.
--
--   Decisiones de diseño (ver f2.1_design_notes §4):
--   - tax_name y tax_rate son snapshot inmutable (no cambian si después se
--     renombra o reasigna la tasa de un impuesto).
--   - ON DELETE CASCADE en order_item_id: si se borra el item antes de
--     pagar (status = draft), las tax_lines van con él.
--   - ON DELETE RESTRICT en tax_id: no se puede borrar un impuesto con
--     historial. Para "borrar" → marcar is_active=false; las nuevas líneas
--     no lo usan, las viejas siguen referenciándolo.
--   - Sin constraint cross-business (OQ2-3, decidida B).
--   - RLS de SELECT vía join transitivo a table_sessions.business_id.
--     Los INSERTs los hace `fn_populate_tax_lines` con SECURITY DEFINER.
--
-- Apply order:
--   1. Staging primero. Verificar que no rompe ningún SELECT existente
--      (la tabla es nueva, no debería).
--   2. Producción.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.order_item_tax_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_item_id   uuid NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
  tax_id          uuid NOT NULL REFERENCES public.taxes(id) ON DELETE RESTRICT,

  -- Snapshot inmutable al momento de la venta:
  tax_name        text NOT NULL,
  tax_rate        numeric(7,4) NOT NULL,
  amount          numeric(12,2) NOT NULL,

  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_oitl_item    ON public.order_item_tax_lines(order_item_id);
CREATE INDEX IF NOT EXISTS idx_oitl_tax     ON public.order_item_tax_lines(tax_id);
CREATE INDEX IF NOT EXISTS idx_oitl_created ON public.order_item_tax_lines(created_at);

ALTER TABLE public.order_item_tax_lines ENABLE ROW LEVEL SECURITY;

-- Policy de SELECT: el usuario puede leer las tax_lines de items que
-- pertenecen a un business al que tiene acceso vía user_businesses.
DROP POLICY IF EXISTS oitl_select ON public.order_item_tax_lines;
CREATE POLICY oitl_select ON public.order_item_tax_lines
  FOR SELECT USING (
    EXISTS (
      SELECT 1
      FROM public.order_items oi
      JOIN public.orders o          ON o.id  = oi.order_id
      JOIN public.table_sessions ts ON ts.id = o.session_id
      WHERE oi.id = order_item_tax_lines.order_item_id
        AND ts.business_id IN (
          SELECT business_id FROM public.user_businesses WHERE user_id = auth.uid()
        )
    )
  );

-- No se definen policies INSERT/UPDATE/DELETE: la tabla sólo se modifica
-- desde `fn_populate_tax_lines` que es SECURITY DEFINER (bypass RLS).

-- ==========================================================================
-- BLOQUE 2 / 8 — Linkear propina a productos que ya tributan (OQ2-5 = A)
-- Source: migrations/01_link_service_fee_to_taxed_products.sql
-- IMPORTANTE: si vas en modo B (uno por uno), pegá ESTE bloque ANTES de
-- aplicar los siguientes. El código actual filtra is_service_fee=false,
-- así que las nuevas filas quedan inertes hasta que el código nuevo entre
-- en vigor.
-- ==========================================================================

-- =============================================================================
-- File:        migrations/01_link_service_fee_to_taxed_products.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.5 — deploy
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes (con DELETE inverso)
-- Rollback:    rollback/migrations/01_unlink_service_fee.sql
--
-- Purpose:
--   Configuración pre-código del modelo unificado (OQ2-5 = A).
--
--   Hoy la propina se aplica globalmente por origin (sin estar linkeada
--   a productos individuales). Cuando se despliegue el código nuevo del
--   PRD 2, la propina pasa a leerse desde `menu_item_taxes` como
--   cualquier otro impuesto. Si no se linkea explícitamente, los
--   productos dejarían de cobrar propina (regresión funcional).
--
--   Este script preserva el comportamiento actual: linkea cada tax con
--   `is_service_fee=true` a TODOS los productos del mismo business que
--   ya tributan al menos un impuesto no-service-fee. Es decir:
--
--   - Producto con ITBIS asociado → además se le linkea la propina del
--     business. Mantiene su comportamiento.
--   - Producto SIN ningún impuesto asociado (los 76 detectados en F2.1)
--     → NO se le linkea propina. Pasa a quedar realmente exento (cierra
--     el bug de "Agua Dasany cobra propina sin estar configurada").
--
--   El operador puede ajustar después vía el script de auditoría
--   `audit/products_without_taxes.sql`.
--
--   El INSERT es idempotente (NOT EXISTS) → puede correrse múltiples
--   veces sin duplicar.
--
-- Apply order:
--   1. Staging (validar conteo).
--   2. Producción, INMEDIATAMENTE ANTES de aplicar los SQL 02-07 del
--      PRD 2 (los que cambian el código). El orden importa porque el
--      código vigente filtra `is_service_fee=false` al leer
--      `menu_item_taxes`, así que las nuevas filas son inertes hasta
--      que el código nuevo entre en vigor.
-- =============================================================================

-- Pre-check: capturar conteo previo (debe ser 0 si nunca se corrió antes).
-- Pegar resultado en bitácora de deploy.
SELECT count(*) AS service_fee_links_before
FROM public.menu_item_taxes mit
JOIN public.taxes t ON t.id = mit.tax_id
WHERE coalesce(t.is_service_fee, false) = true;

-- Aplicar:
INSERT INTO public.menu_item_taxes (item_id, tax_id)
SELECT mi.id, t.id
FROM public.menu_items mi
JOIN public.taxes t
  ON t.business_id = mi.business_id
WHERE coalesce(t.is_service_fee, false) = true
  AND coalesce(t.is_active, true)
  -- Solo productos que ya tributan AL MENOS un impuesto no-service-fee.
  -- Esto preserva el comportamiento actual sin agregar propina a los
  -- productos que están explícitamente exentos.
  AND EXISTS (
    SELECT 1
    FROM public.menu_item_taxes existing
    JOIN public.taxes et ON et.id = existing.tax_id
    WHERE existing.item_id = mi.id
      AND coalesce(et.is_service_fee, false) = false
  )
  -- Idempotencia: no insertar si ya existe el link.
  AND NOT EXISTS (
    SELECT 1
    FROM public.menu_item_taxes mit2
    WHERE mit2.item_id = mi.id AND mit2.tax_id = t.id
  );

-- Post-check: confirmar conteo después.
SELECT count(*) AS service_fee_links_after
FROM public.menu_item_taxes mit
JOIN public.taxes t ON t.id = mit.tax_id
WHERE coalesce(t.is_service_fee, false) = true;

-- ==========================================================================
-- BLOQUE 3 / 8 — fn_populate_tax_lines + trigger AFTER (PRD §6.5 ajustado)
-- Source: 02_f2.2_fn_populate_tax_lines.sql
-- ==========================================================================

-- =============================================================================
-- File:        02_f2.2_fn_populate_tax_lines.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes
-- Rollback:    rollback/02_drop_populate_tax_lines.sql
--
-- Purpose:
--   Función + trigger AFTER que popla `order_item_tax_lines` con un
--   snapshot por cada impuesto que aplica al item.
--
--   Diseño:
--   - AFTER INSERT/UPDATE en order_items garantiza que NEW.id ya está
--     persistido y que NEW.subtotal ya fue calculado por el trigger BEFORE
--     `fn_compute_item_totals`.
--   - En UPDATE: borra las tax_lines previas y reescribe (idempotente).
--   - Lee `menu_item_taxes` filtrado por origin del order. La columna
--     `is_service_fee` ya NO se filtra (OQ2-5 = A: la propina pasa por
--     menu_item_taxes como cualquier otro impuesto).
--   - amount = round(NEW.subtotal * tax.rate / 100, 2). Si la suma de
--     amounts difiere de NEW.tax por redondeo, NO se ajusta acá: el
--     desfase quedará registrado en la tabla y los reportes del PRD 3
--     pueden reconciliar al centavo más cercano.
--   - Self_service y origins desconocidos → no se insertan tax_lines y
--     se RAISE EXCEPTION (fail-loud, OQ2-1 = B).
--
-- Apply order:
--   1. Staging primero.
--   2. Después del SQL 01 (la tabla destino debe existir).
--   3. Antes del SQL 06 (que reescribe fn_add_item_from_menu y depende
--      de que las tax_lines se generen automáticamente).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_populate_tax_lines()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_origin text;
  v_biz_id uuid;
  v_tax record;
BEGIN
  -- Idempotencia: en UPDATE borramos las líneas previas para reescribir.
  -- En INSERT no hay nada que borrar pero el DELETE no falla.
  DELETE FROM public.order_item_tax_lines
  WHERE order_item_id = NEW.id;

  -- Si el item está void, no escribimos tax_lines (no se cobra nada).
  IF NEW.status = 'void' THEN
    RETURN NEW;
  END IF;

  -- Obtener origin y business_id del order al que pertenece el item.
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO v_origin, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = NEW.order_id;

  -- Fail-loud para origins no soportados (PRD 2 OQ2-1).
  IF v_origin = 'self_service' THEN
    RAISE EXCEPTION 'self_service origin not supported (PRD 2 fail-loud): self-checkout aún no implementado';
  END IF;

  IF v_origin IS NULL OR v_origin NOT IN ('dine_in', 'manual', 'quick', 'delivery') THEN
    RAISE EXCEPTION 'unknown order_origin: %', v_origin;
  END IF;

  -- Insertar una fila por cada impuesto del producto que aplica al origin.
  -- Snapshot: tax_name y tax_rate al momento de la venta.
  FOR v_tax IN
    SELECT t.id AS tax_id, t.name AS tax_name, t.rate AS tax_rate
    FROM public.menu_item_taxes mit
    JOIN public.taxes t ON t.id = mit.tax_id
    WHERE mit.item_id = NEW.product_id
      AND t.business_id = v_biz_id
      AND coalesce(t.is_active, true)
      AND (
        (v_origin = 'dine_in'  AND t.apply_on_zone)     OR
        (v_origin = 'manual'   AND t.apply_on_manual)   OR
        (v_origin = 'quick'    AND t.apply_on_quick)    OR
        (v_origin = 'delivery' AND t.apply_on_delivery)
      )
      -- Takeout no paga service fee aunque esté linkeado y aplique al origin:
      AND NOT (NEW.is_takeout AND coalesce(t.is_service_fee, false))
  LOOP
    INSERT INTO public.order_item_tax_lines (
      order_item_id, tax_id, tax_name, tax_rate, amount
    ) VALUES (
      NEW.id,
      v_tax.tax_id,
      v_tax.tax_name,
      v_tax.tax_rate,
      ROUND(coalesce(NEW.subtotal, 0) * (v_tax.tax_rate / 100.0), 2)
    );
  END LOOP;

  RETURN NEW;
END;
$function$;

-- Trigger AFTER que dispara después de que `fn_compute_item_totals` (BEFORE)
-- ya seteó subtotal/tax/total y de que el row está persistido (NEW.id existe).
DROP TRIGGER IF EXISTS trg_populate_tax_lines ON public.order_items;
CREATE TRIGGER trg_populate_tax_lines
  AFTER INSERT OR UPDATE OF subtotal, status, product_id, order_id, is_takeout
  ON public.order_items
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_populate_tax_lines();

-- ==========================================================================
-- BLOQUE 4 / 8 — fn_recalc_totals: motor unificado (PRD §6.2)
-- Source: 03_f2.2_fn_recalc_totals.sql
-- ==========================================================================

-- =============================================================================
-- File:        03_f2.2_fn_recalc_totals.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes
-- Rollback:    rollback/03_drop_fn_recalc_totals.sql
--
-- Purpose:
--   Función única consolidada que reemplaza la lógica de
--   `calculate_order_totals` y `calculate_check_totals`. Una sola fuente
--   de verdad para los totales de orden y check.
--
--   Diferencias clave respecto al estado actual:
--   - NO lee `business_settings.service_fee_*` ni `default_tax_rate` (G2).
--   - NO calcula service_fee separadamente: la propina ya viene incluida
--     en `oi.tax` cuando aplica (porque `fn_add_item_from_menu` la sumó
--     al `tax_rate` del item).
--   - `service_fee` en orders/order_checks queda siempre en 0 (G6).
--   - Sin CASE statements con valores fantasma del enum (G3).
--   - Una sola pasada para orden y todos sus checks.
--
--   PRECISIÓN: se preserva EXACTAMENTE la lógica de redondeo actual
--   (no es scope del PRD 2 cambiarla):
--     orders.subtotal, orders.tax       → 4 decimales (precisión interna)
--     orders.discounts, orders.total    → 2 decimales (visible al usuario)
--     order_checks.*                    → 2 decimales (igual que hoy)
--   Si en el futuro se detecta drift por inconsistencia 4-vs-2 entre
--   orders y order_checks, se arregla en un PR dedicado a redondeo, no
--   escondido en este refactor.
--
-- Apply order:
--   1. Staging.
--   2. Después del SQL 01 y 02. Antes del SQL 04 (los wrappers).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_recalc_totals(_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- 1. Recalcular totales por check.
  WITH check_totals AS (
    SELECT
      oi.check_id,
      COALESCE(SUM(oi.subtotal),  0) AS subtotal,
      COALESCE(SUM(oi.tax),       0) AS tax,
      COALESCE(SUM(oi.discounts), 0) AS discounts
    FROM public.order_items oi
    WHERE oi.order_id = _order_id
      AND oi.status NOT IN ('void')
      AND oi.check_id IS NOT NULL
    GROUP BY oi.check_id
  )
  UPDATE public.order_checks oc SET
    subtotal    = ROUND(ct.subtotal,  2),
    tax         = ROUND(ct.tax,       2),
    discounts   = ROUND(ct.discounts, 2),
    service_fee = 0,  -- modelo unificado: la propina vive dentro de tax
    total       = ROUND(ct.subtotal + ct.tax - ct.discounts, 2)
  FROM check_totals ct
  WHERE oc.id = ct.check_id;

  -- 1b. Checks que quedaron sin items (todos void o vacío) → totales en 0.
  UPDATE public.order_checks oc SET
    subtotal = 0, tax = 0, discounts = 0, service_fee = 0, total = 0
  WHERE oc.order_id = _order_id
    AND NOT EXISTS (
      SELECT 1 FROM public.order_items oi
      WHERE oi.check_id = oc.id AND oi.status NOT IN ('void')
    );

  -- 2. Recalcular totales del order.
  --    Preservamos la convención de redondeo del código original:
  --    4 decimales en subtotal/tax (precisión interna), 2 en discounts/total.
  UPDATE public.orders o SET
    subtotal    = COALESCE((
      SELECT ROUND(SUM(oi.subtotal),  4) FROM public.order_items oi
      WHERE oi.order_id = _order_id AND oi.status NOT IN ('void')
    ), 0),
    tax         = COALESCE((
      SELECT ROUND(SUM(oi.tax),       4) FROM public.order_items oi
      WHERE oi.order_id = _order_id AND oi.status NOT IN ('void')
    ), 0),
    discounts   = COALESCE((
      SELECT ROUND(SUM(oi.discounts), 2) FROM public.order_items oi
      WHERE oi.order_id = _order_id AND oi.status NOT IN ('void')
    ), 0),
    service_fee = 0,  -- modelo unificado (G6); no es cambio de redondeo
    total       = COALESCE((
      SELECT ROUND(SUM(oi.subtotal + oi.tax - oi.discounts), 2)
      FROM public.order_items oi
      WHERE oi.order_id = _order_id AND oi.status NOT IN ('void')
    ), 0)
  WHERE o.id = _order_id;
END;
$function$;

-- ==========================================================================
-- BLOQUE 5 / 8 — Wrappers de calculate_order_totals/calculate_check_totals (PRD §6.3)
-- Source: 04_f2.2_calculate_totals_wrappers.sql
-- ==========================================================================

-- =============================================================================
-- File:        04_f2.2_calculate_totals_wrappers.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes (restaurar desde snapshots/03 y snapshots/04)
-- Rollback:    rollback/04_restore_calculate_functions.sql
--
-- Purpose:
--   Convierte `calculate_order_totals` y `calculate_check_totals` en
--   wrappers triviales que delegan a `fn_recalc_totals` (PRD §6.3).
--
--   Razón: hay código (frontend, RPCs como `fn_recalc_order_totals`) que
--   llama a estas funciones. En vez de buscar y reemplazar todos los
--   call-sites, dejamos las firmas viejas y redireccionamos. Esto reduce
--   el blast radius del PRD 2.
--
--   `calculate_check_totals(_check_id)` recibe un check_id pero el motor
--   nuevo trabaja a nivel orden. Resolvemos el order_id desde el check_id
--   y llamamos a `fn_recalc_totals(order_id)`, que recalcula la orden Y
--   todos sus checks (incluido el que se nos pasó).
--
-- Apply order:
--   1. Staging.
--   2. Después de SQL 03 (fn_recalc_totals debe existir).
--   3. Antes de SQL 05 (que va a llamar a estos wrappers desde el trigger).
-- =============================================================================

-- Wrapper de calculate_order_totals
CREATE OR REPLACE FUNCTION public.calculate_order_totals(_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- DEPRECATED: usar fn_recalc_totals directamente.
  -- Wrapper preservado para compatibilidad con call-sites que aún la usan.
  PERFORM public.fn_recalc_totals(_order_id);
END;
$function$;

-- Wrapper de calculate_check_totals
CREATE OR REPLACE FUNCTION public.calculate_check_totals(_check_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _order_id uuid;
BEGIN
  -- DEPRECATED: el cálculo se hace a nivel orden.
  -- Buscamos la orden a la que pertenece el check y delegamos.
  SELECT order_id INTO _order_id
  FROM public.order_checks
  WHERE id = _check_id;

  IF _order_id IS NOT NULL THEN
    PERFORM public.fn_recalc_totals(_order_id);
  END IF;
END;
$function$;

-- ==========================================================================
-- BLOQUE 6 / 8 — Simplificar trigger_update_order_totals (PRD §6.4)
-- Source: 05_f2.2_trigger_update_order_totals.sql
-- ==========================================================================

-- =============================================================================
-- File:        05_f2.2_trigger_update_order_totals.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes
-- Rollback:    rollback/05_restore_trigger_update_order_totals.sql
--
-- Purpose:
--   Simplifica el cuerpo de `trigger_update_order_totals` (la función
--   bound al trigger AFTER `order_items_totals_trigger` en order_items).
--
--   Cambio: una sola llamada a `fn_recalc_totals(order_id)` en cada caso,
--   en lugar de las dos llamadas actuales (`calculate_order_totals` +
--   `calculate_check_totals`). El motor nuevo recalcula la orden Y todos
--   sus checks en una pasada, así que no necesitamos llamarlas por
--   separado.
--
--   El TRIGGER en sí (`order_items_totals_trigger`) NO se toca: sigue
--   siendo AFTER INSERT OR DELETE OR UPDATE FOR EACH ROW.
--
-- Apply order:
--   1. Staging.
--   2. Después del SQL 03 (fn_recalc_totals debe existir) y SQL 04
--      (los wrappers, por si algún call-site externo los usa).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trigger_update_order_totals()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.fn_recalc_totals(OLD.order_id);
    RETURN OLD;
  END IF;

  -- INSERT o UPDATE: recalcular para el order_id (nuevo o el viejo si UPDATE).
  PERFORM public.fn_recalc_totals(COALESCE(NEW.order_id, OLD.order_id));

  -- Si en UPDATE el item se movió a otro order (poco común pero posible),
  -- también recalcular el order viejo para no dejarlo desactualizado.
  IF TG_OP = 'UPDATE'
     AND OLD.order_id IS NOT NULL
     AND OLD.order_id IS DISTINCT FROM NEW.order_id THEN
    PERFORM public.fn_recalc_totals(OLD.order_id);
  END IF;

  RETURN NEW;
END;
$function$;

-- ==========================================================================
-- BLOQUE 7 / 8 — Simplificar fn_resolve_order_item_tax_profile (G3 + OQ2-5 + OQ2-1)
-- Source: 06_f2.2_fn_resolve_order_item_tax_profile.sql
-- ==========================================================================

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

-- ==========================================================================
-- BLOQUE 8 / 8 — Reescribir fn_add_item_from_menu (PRD §6.6)
-- Source: 07_f2.2_fn_add_item_from_menu.sql
-- ==========================================================================

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

-- ==============================================================================
-- FIN DE F2.2
-- ==============================================================================

COMMIT;
