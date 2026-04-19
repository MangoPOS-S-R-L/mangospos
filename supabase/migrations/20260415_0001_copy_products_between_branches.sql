-- =============================================================================
-- RPC: Copy products catalog from one business to another.
-- Copies: categories → menu_items → menus → menu_item_links
-- Does NOT copy: images (references stay, storage paths not cloned),
-- taxes (new branch should configure its own), inventory.
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
  v_cat_map jsonb := '{}';  -- old_category_id → new_category_id
  v_item_map jsonb := '{}'; -- old_item_id → new_item_id
  v_menu_map jsonb := '{}'; -- old_menu_id → new_menu_id
  v_cat RECORD;
  v_item RECORD;
  v_menu RECORD;
  v_link RECORD;
  v_new_id uuid;
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

  -- 1. Copy categories
  FOR v_cat IN
    SELECT * FROM public.categories
    WHERE business_id = p_source_business_id
    ORDER BY position, name
  LOOP
    INSERT INTO public.categories (
      business_id, name, description, image_url, position, is_active, created_at
    ) VALUES (
      p_target_business_id, v_cat.name, v_cat.description,
      v_cat.image_url, v_cat.position, v_cat.is_active, now()
    ) RETURNING id INTO v_new_id;

    v_cat_map := v_cat_map || jsonb_build_object(v_cat.id::text, v_new_id::text);
    v_categories_copied := v_categories_copied + 1;
  END LOOP;

  -- 2. Copy menu_items
  FOR v_item IN
    SELECT * FROM public.menu_items
    WHERE business_id = p_source_business_id
    ORDER BY position, name
  LOOP
    -- Resolve new category_id
    INSERT INTO public.menu_items (
      business_id, category_id, name, description, price, cost,
      barcode, sku, image_url, image_path, is_active, sold_by,
      tax_mode, has_variants, has_prep, prep_minutes,
      dietary, contains_egg, is_beverage, print_area_code,
      position, created_at, updated_at
    ) VALUES (
      p_target_business_id,
      CASE
        WHEN v_item.category_id IS NOT NULL
        THEN (v_cat_map ->> v_item.category_id::text)::uuid
        ELSE NULL
      END,
      v_item.name, v_item.description, v_item.price, v_item.cost,
      v_item.barcode, v_item.sku, v_item.image_url, v_item.image_path,
      v_item.is_active, v_item.sold_by,
      v_item.tax_mode, v_item.has_variants, v_item.has_prep, v_item.prep_minutes,
      v_item.dietary, v_item.contains_egg, v_item.is_beverage,
      COALESCE(v_item.print_area_code, 'kitchen_hot'),
      v_item.position, now(), now()
    ) RETURNING id INTO v_new_id;

    v_item_map := v_item_map || jsonb_build_object(v_item.id::text, v_new_id::text);
    v_items_copied := v_items_copied + 1;
  END LOOP;

  -- 3. Copy menus
  FOR v_menu IN
    SELECT * FROM public.menus
    WHERE business_id = p_source_business_id
    ORDER BY name
  LOOP
    INSERT INTO public.menus (
      business_id, name, description, is_active, created_at
    ) VALUES (
      p_target_business_id, v_menu.name, v_menu.description,
      v_menu.is_active, now()
    ) RETURNING id INTO v_new_id;

    v_menu_map := v_menu_map || jsonb_build_object(v_menu.id::text, v_new_id::text);
    v_menus_copied := v_menus_copied + 1;
  END LOOP;

  -- 4. Copy menu_item_links (product ↔ menu assignments)
  FOR v_link IN
    SELECT mil.* FROM public.menu_item_links mil
    JOIN public.menus m ON mil.menu_id = m.id
    WHERE m.business_id = p_source_business_id
  LOOP
    -- Only copy if both menu and item were copied
    IF (v_menu_map ? v_link.menu_id::text) AND (v_item_map ? v_link.item_id::text) THEN
      INSERT INTO public.menu_item_links (
        menu_id, item_id, position
      ) VALUES (
        (v_menu_map ->> v_link.menu_id::text)::uuid,
        (v_item_map ->> v_link.item_id::text)::uuid,
        v_link.position
      ) ON CONFLICT DO NOTHING;
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
