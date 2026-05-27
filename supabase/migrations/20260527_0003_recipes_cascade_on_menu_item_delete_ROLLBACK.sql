-- Rollback de 20260527_0003: vuelve `recipes_menu_item_id_fkey` a NO ACTION
-- (default). Esto re-bloquea el delete de productos con receta y obliga al
-- caller a manejar 23503 manualmente.

ALTER TABLE public.recipes
  DROP CONSTRAINT IF EXISTS recipes_menu_item_id_fkey;

ALTER TABLE public.recipes
  ADD CONSTRAINT recipes_menu_item_id_fkey
  FOREIGN KEY (menu_item_id)
  REFERENCES public.menu_items(id);
