-- =============================================================================
-- PRD 6.1 · F1 — Umbral de variación de costo por negocio.
--
-- CONTEXTO:
--   El PRD 6.1 original proponía además avg_cost en inventory_stock,
--   itbis_pct y unidades de compra por línea de OC. Nada de eso hace falta:
--   el costeo ponderado ya existe (fn_recompute_item_cost_weighted_avg +
--   20260714 last_price_recost), purchase_order_items ya tiene tax_rate
--   (default 18) y la conversión de empaque vive en
--   inventory_items.purchase_unit/pack_size. Este archivo solo agrega el
--   umbral que dispara la aprobación de variación en la RPC v2.
--
-- ENTREGA:
--   - business_settings.cost_variance_threshold_pct (default 3%): si el costo
--     real de una línea difiere del costo de la OC por encima de este
--     porcentaje, la recepción exige approved_by (o registra auto-aprobación
--     en bitácora). Mismo patrón que cash_variance_alert_threshold.
--
-- IDEMPOTENTE / BACKWARDS-COMPATIBLE:
--   - Columna con default; nada existente cambia de comportamiento.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists cost_variance_threshold_pct numeric(6,3) default 3 not null;

comment on column public.business_settings.cost_variance_threshold_pct is
  'Porcentaje de variación entre el costo de la OC y el costo real facturado '
  'a partir del cual la recepción requiere aprobación (approved_by). '
  '0 = toda variación requiere aprobación explícita.';

commit;
