-- =============================================================================
-- PRD 6.2 C.2 — Suplidor preferido por insumo.
--
-- CONTEXTO:
--   "Qué comprar hoy" agrupa por el suplidor de la ÚLTIMA compra (heurística
--   de v_inventory_reorder_suggestions). El suplidor preferido, cuando está
--   configurado en la ficha del artículo, manda sobre esa heurística.
--
-- IDEMPOTENTE / BACKWARDS-COMPATIBLE:
--   - Columna nullable con FK on delete set null; nada existente cambia.
-- =============================================================================

begin;

alter table public.inventory_items
  add column if not exists preferred_supplier_id uuid
    references public.suppliers(id) on delete set null;

create index if not exists idx_inventory_items_preferred_supplier
  on public.inventory_items (preferred_supplier_id)
  where preferred_supplier_id is not null;

comment on column public.inventory_items.preferred_supplier_id is
  'Suplidor preferido del insumo. Cuando existe, "Qué comprar hoy" agrupa '
  'por él en vez del suplidor de la última compra.';

commit;
