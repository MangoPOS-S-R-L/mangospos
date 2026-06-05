-- =============================================================================
-- ROLLBACK 20260604_0001 — order_items.promotion_id
-- =============================================================================
-- Revierte la atribución de oferta por línea. Seguro: la columna es aditiva y
-- nullable, así que dropearla no afecta ventas existentes (solo se pierde la
-- atribución de promo). Ejecutar en orden inverso: índice → FK → columna.
-- =============================================================================

drop index if exists public.idx_order_items_promotion_id;

alter table public.order_items
  drop constraint if exists order_items_promotion_id_fkey;

alter table public.order_items
  drop column if exists promotion_id;
