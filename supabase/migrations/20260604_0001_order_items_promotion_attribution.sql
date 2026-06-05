-- =============================================================================
-- 20260604_0001 — order_items.promotion_id: atribución de oferta por línea
-- =============================================================================
--
-- PROBLEMA QUE RESUELVE
-- ─────────────────────
-- Hoy, cuando una promoción/oferta se aplica a una línea de venta, la única
-- "marca" de qué promo se aplicó es un texto incrustado en `order_items.notes`
-- con el formato `[PROMO_AUTO:<promo-id>]` (ver `_buildAutoPromoNotes` en
-- lib/presentation/sales/viewmodel/sales_viewmodel.dart).
--
-- Eso es frágil para dos cosas que necesitamos (PRD Ofertas/Combos/Inventario):
--   1. Aplicar ofertas de forma confiable en TODOS los flujos (mesas/zonas,
--      venta rápida, retail) — necesitamos saber qué línea ya tiene promo.
--   2. Reporte "Ventas por oferta" — agrupar ventas por promoción sin tener
--      que parsear texto libre de `notes`.
--
-- FIX
-- ───
-- Columna estructurada `order_items.promotion_id uuid` (FK a `promotions`),
-- que el motor de ofertas poblará al aplicar una promo a la línea. El marcador
-- en `notes` puede mantenerse temporalmente por compatibilidad, pero la fuente
-- de verdad pasa a ser esta columna.
--
-- NOTAS DE SEGURIDAD
--   - 100% ADITIVA: la columna es NULLABLE; las ventas existentes y el flujo de
--     restaurante actual no cambian de comportamiento.
--   - FK con ON DELETE SET NULL: si se borra una promo, la venta NO se rompe;
--     la línea solo pierde la atribución.
--   - FK declarada NOT VALID: evita un scan/lock de validación sobre filas
--     históricas (todas NULL hoy). Las inserciones/updates NUEVOS SÍ se validan.
--     Si más adelante se desea validar el histórico: `VALIDATE CONSTRAINT`.
-- =============================================================================

alter table public.order_items
  add column if not exists promotion_id uuid;

comment on column public.order_items.promotion_id is
  'Oferta/promoción aplicada a esta línea. Fuente de verdad para aplicar promos en todos los flujos y para el reporte de ventas por oferta. Reemplaza el marcador [PROMO_AUTO:id] en notes.';

-- FK idempotente y NOT VALID (sin scan de histórico).
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'order_items_promotion_id_fkey'
  ) then
    alter table public.order_items
      add constraint order_items_promotion_id_fkey
      foreign key (promotion_id) references public.promotions(id)
      on delete set null
      not valid;
  end if;
end$$;

-- Índice parcial: solo líneas con oferta (acelera el reporte por promo).
create index if not exists idx_order_items_promotion_id
  on public.order_items (promotion_id)
  where promotion_id is not null;
