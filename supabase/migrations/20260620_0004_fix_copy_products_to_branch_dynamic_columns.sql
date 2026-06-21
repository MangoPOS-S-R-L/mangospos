-- =============================================================================
-- FIX: fn_copy_products_to_branch hardcodeaba columnas que NO existen en la BD
-- viva (categories.description / image_url, menu_items.tax_mode / dietary /
-- contains_egg / is_beverage / position), lo que provocaba errores 42703
-- "column ... does not exist" al crear una sucursal copiando productos.
--
-- Esta versión copia DINÁMICAMENTE solo las columnas que realmente existen en
-- cada tabla (vía information_schema), excluyendo PK / business_id / FKs que se
-- remapean. Así queda inmune a la divergencia esquema-repo: copia lo que haya,
-- ni más ni menos, sin perder columnas reales (presentation,
-- is_inventory_tracked, allow_negative_sale, etc.).
--
-- Además genera el id nuevo con gen_random_uuid() en vez de depender de un
-- DEFAULT en la columna id: categories.id NO tiene default (la app genera el
-- UUID en el cliente), así que confiar en RETURNING/default rompía con
-- "null value in column id ... violates not-null". Pasar el id explícito
-- funciona tanto si hay default como si no.
--
-- Copia: categories -> menu_items -> menus -> menu_item_links
-- NO copia: inventario, impuestos (la sucursal configura los suyos).
-- =============================================================================

CREATE OR REPLACE FUNCTION "public"."fn_copy_products_to_branch"(
  "p_source_business_id" "uuid",
  "p_target_business_id" "uuid"
) RETURNS jsonb
LANGUAGE "plpgsql"
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
DECLARE
  v_cat_map jsonb := '{}';  -- old_category_id -> new_category_id
  v_item_map jsonb := '{}'; -- old_item_id -> new_item_id
  v_menu_map jsonb := '{}'; -- old_menu_id -> new_menu_id
  v_rec RECORD;
  v_new_id uuid;
  v_new_menu_id uuid;
  v_new_item_id uuid;
  v_cat_cols text;
  v_item_cols text;
  v_menu_cols text;
  v_categories_copied int := 0;
  v_items_copied int := 0;
  v_menus_copied int := 0;
  v_links_copied int := 0;
BEGIN
  -- Validate
  IF p_source_business_id IS NULL OR p_target_business_id IS NULL THEN
    RAISE EXCEPTION 'source and target business_id are required';
  END IF;
  IF p_source_business_id = p_target_business_id THEN
    RAISE EXCEPTION 'source and target must be different';
  END IF;

  -- Listas de columnas reales (excluye PK/FK que controlamos manualmente y
  -- columnas generadas que no se pueden insertar).
  SELECT string_agg(quote_ident(column_name), ', ')
    INTO v_cat_cols
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'categories'
     AND column_name NOT IN ('id', 'business_id')
     AND is_generated = 'NEVER'
     AND is_identity = 'NO';

  SELECT string_agg(quote_ident(column_name), ', ')
    INTO v_item_cols
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'menu_items'
     AND column_name NOT IN ('id', 'business_id', 'category_id')
     AND is_generated = 'NEVER'
     AND is_identity = 'NO';

  SELECT string_agg(quote_ident(column_name), ', ')
    INTO v_menu_cols
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'menus'
     AND column_name NOT IN ('id', 'business_id')
     AND is_generated = 'NEVER'
     AND is_identity = 'NO';

  -- 1. categories
  FOR v_rec IN
    SELECT id FROM public.categories
    WHERE business_id = p_source_business_id
  LOOP
    v_new_id := gen_random_uuid();
    EXECUTE format(
      'INSERT INTO public.categories (id, business_id, %1$s) '
      'SELECT $1, $3, %1$s FROM public.categories WHERE id = $2',
      v_cat_cols
    ) USING v_new_id, v_rec.id, p_target_business_id;

    v_cat_map := v_cat_map || jsonb_build_object(v_rec.id::text, v_new_id::text);
    v_categories_copied := v_categories_copied + 1;
  END LOOP;

  -- 2. menu_items (remapea category_id al nuevo id)
  FOR v_rec IN
    SELECT id, category_id FROM public.menu_items
    WHERE business_id = p_source_business_id
  LOOP
    v_new_id := gen_random_uuid();
    EXECUTE format(
      'INSERT INTO public.menu_items (id, business_id, category_id, %1$s) '
      'SELECT $1, $3, $4, %1$s FROM public.menu_items WHERE id = $2',
      v_item_cols
    )
    USING v_new_id,
          v_rec.id,
          p_target_business_id,
          CASE
            WHEN v_rec.category_id IS NOT NULL
            THEN (v_cat_map ->> v_rec.category_id::text)::uuid
            ELSE NULL
          END;

    v_item_map := v_item_map || jsonb_build_object(v_rec.id::text, v_new_id::text);
    v_items_copied := v_items_copied + 1;
  END LOOP;

  -- 3. menus
  FOR v_rec IN
    SELECT id FROM public.menus
    WHERE business_id = p_source_business_id
  LOOP
    v_new_id := gen_random_uuid();
    EXECUTE format(
      'INSERT INTO public.menus (id, business_id, %1$s) '
      'SELECT $1, $3, %1$s FROM public.menus WHERE id = $2',
      v_menu_cols
    ) USING v_new_id, v_rec.id, p_target_business_id;

    v_menu_map := v_menu_map || jsonb_build_object(v_rec.id::text, v_new_id::text);
    v_menus_copied := v_menus_copied + 1;
  END LOOP;

  -- 4. menu_item_links (asignaciones producto <-> menu)
  FOR v_rec IN
    SELECT mil.menu_id, mil.item_id, mil.position
    FROM public.menu_item_links mil
    JOIN public.menus m ON mil.menu_id = m.id
    WHERE m.business_id = p_source_business_id
  LOOP
    -- Solo copiar si ambos (menu e item) fueron copiados
    IF (v_menu_map ? v_rec.menu_id::text) AND (v_item_map ? v_rec.item_id::text) THEN
      v_new_menu_id := (v_menu_map ->> v_rec.menu_id::text)::uuid;
      v_new_item_id := (v_item_map ->> v_rec.item_id::text)::uuid;

      INSERT INTO public.menu_item_links (menu_id, item_id, position)
      VALUES (v_new_menu_id, v_new_item_id, v_rec.position)
      ON CONFLICT DO NOTHING;

      v_links_copied := v_links_copied + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'categories_copied', v_categories_copied,
    'items_copied', v_items_copied,
    'menus_copied', v_menus_copied,
    'links_copied', v_links_copied
  );
END;
$$;

-- Recarga el cache de PostgREST (no cambia la firma, pero es barato y seguro).
NOTIFY pgrst, 'reload schema';
