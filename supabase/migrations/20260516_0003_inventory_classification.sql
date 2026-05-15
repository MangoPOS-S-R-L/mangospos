-- =============================================================================
-- Inventario PRD: clasificación de items.
--
-- CONCEPTO:
--   Discrimina los `inventory_items` según su rol en el flujo:
--     - 'simple'           → item genérico (default, backwards compat)
--     - 'raw_material'     → materia prima (entra por compras, sale por producción)
--     - 'finished_product' → producto terminado (sale por venta, entra por producción)
--     - 'combo'            → producto compuesto sin receta de producción
--     - 'service'          → servicio (no afecta stock físico)
--
--   Esta clasificación habilita el flujo de producción: una orden de
--   producción consume raw_material y produce finished_product. Sin la
--   clasificación, no podemos distinguir qué transformar en qué.
--
-- ENTREGA:
--   1. Columna `item_classification text DEFAULT 'simple'` con CHECK constraint.
--   2. Index para queries por tipo (útil en reportes).
--
-- IMPACTO EN PRODUCCIÓN:
--   ⚠️ Items existentes quedan en 'simple' (default). El sistema sigue
--   funcionando exactamente igual hasta que el admin marque manualmente
--   cuáles son raw_material / finished_product. Producción se activa solo
--   cuando hay items clasificados.
--
-- IDEMPOTENTE: ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS.
-- =============================================================================

begin;

alter table public.inventory_items
  add column if not exists item_classification text
    not null
    default 'simple';

-- CHECK con valores válidos (idempotente: drop si existe, recrear)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'inventory_items_classification_check'
  ) then
    alter table public.inventory_items
      add constraint inventory_items_classification_check
      check (item_classification in (
        'simple', 'raw_material', 'finished_product', 'combo', 'service'
      ));
  end if;
end $$;

create index if not exists idx_inventory_items_classification
  on public.inventory_items (business_id, item_classification);

comment on column public.inventory_items.item_classification is
  'Discrimina el rol del item en el flujo de inventario: simple (default), '
  'raw_material (consumido por producción), finished_product (producido por '
  'producción), combo (compuesto sin transformación), service (no físico).';

commit;
