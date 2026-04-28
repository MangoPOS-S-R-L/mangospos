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
