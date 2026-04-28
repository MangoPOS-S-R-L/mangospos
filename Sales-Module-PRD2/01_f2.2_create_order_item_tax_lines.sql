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
