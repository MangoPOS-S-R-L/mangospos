-- =============================================================================
-- Fix: deleteProduct bloqueado por FK `recipes_menu_item_id_fkey` sin CASCADE.
--
-- Contexto: cuando un comercio intenta borrar un menu_item que tiene receta
-- definida (ingredientes vinculados), Postgres tira
-- `23503 foreign_key_violation` porque la FK era ON NO ACTION (default).
-- El owner veía error críptico y no podía limpiar su catálogo.
--
-- Decisión: la receta describe CÓMO se hace ese producto específico. Si el
-- producto desaparece, la receta pierde sentido — debe morir con él.
-- ON DELETE CASCADE es lo semánticamente correcto.
--
-- El resto de FKs que apuntan a menu_items ya están bien:
--   - menu_item_groups, menu_item_links, menu_item_taxes:    CASCADE ✓
--   - menu_item_print_areas:                                 CASCADE ✓
--   - order_items.product_id:                                SET NULL ✓ (preserva el ticket)
--
-- Tras esta migration, hard delete de producto siempre funciona y el
-- histórico fiscal queda intacto (order_items conserva product_name,
-- unit_price snapshotted).
-- =============================================================================

ALTER TABLE public.recipes
  DROP CONSTRAINT IF EXISTS recipes_menu_item_id_fkey;

ALTER TABLE public.recipes
  ADD CONSTRAINT recipes_menu_item_id_fkey
  FOREIGN KEY (menu_item_id)
  REFERENCES public.menu_items(id)
  ON DELETE CASCADE;
