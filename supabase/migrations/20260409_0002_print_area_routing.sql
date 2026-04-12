-- =============================================================================
-- Migration: print_area_code on menu_items + order_items
-- Purpose: Allow products to be assigned to a print area (kitchen, bar, etc.)
--          so that commands are routed to the correct printer.
-- =============================================================================

-- 1. Add print_area_code to menu_items (where admin configures it)
ALTER TABLE public.menu_items
  ADD COLUMN IF NOT EXISTS print_area_code text NOT NULL DEFAULT 'kitchen_hot';

COMMENT ON COLUMN public.menu_items.print_area_code
  IS 'Code of the print area where this item should print (kitchen_hot, kitchen_cold, bar, cashier).';

-- 2. Add print_area_code to order_items (propagated when item is added to order)
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS print_area_code text NOT NULL DEFAULT 'kitchen_hot';

CREATE INDEX IF NOT EXISTS idx_order_items_print_area_code
  ON public.order_items(print_area_code);

-- 3. Update fn_add_item_from_menu to propagate print_area_code from menu_item to order_item
CREATE OR REPLACE FUNCTION "public"."fn_add_item_from_menu"(
  "p_order_id" "uuid",
  "p_menu_item_id" "uuid",
  "p_qty" numeric DEFAULT 1,
  "p_check_position" integer DEFAULT 1,
  "p_is_takeout" boolean DEFAULT false,
  "p_notes" "text" DEFAULT NULL::"text"
) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_name text;
  v_price numeric(12,2);
  v_tax_mode text;
  v_tax_rate numeric := 0;
  v_full_tax_rate numeric := 0;
  v_print_area_code text;
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
begin
  v_qty := greatest(coalesce(p_qty, 1), 1);

  select name, price, coalesce(print_area_code, 'kitchen_hot')
    into v_name, v_price, v_print_area_code
  from public.menu_items
  where id = p_menu_item_id
  limit 1;

  if v_name is null then
    raise exception 'MENU_ITEM_NOT_FOUND';
  end if;

  -- Tasa filtrada por origin (la que se aplica)
  select profile.tax_mode, profile.tax_rate
    into v_tax_mode, v_tax_rate
  from public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

  -- Tasa completa (todos los impuestos activos del negocio, sin filtrar por origin)
  select coalesce(sum(t.rate), 0)::numeric
    into v_full_tax_rate
  from public.taxes t
  where t.business_id = (
    select ts.business_id from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    where o.id = p_order_id limit 1
  )
    and coalesce(t.is_active, true);

  -- Si no hay impuestos configurados, la tasa completa = la filtrada
  if v_full_tax_rate = 0 then
    v_full_tax_rate := v_tax_rate;
  end if;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  insert into public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, tax_mode, tax_rate, original_tax_rate,
    is_takeout, notes, status, print_area_code
  ) values (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, v_qty, v_price, coalesce(v_tax_mode, 'exclusive'),
    coalesce(v_tax_rate, 0), v_full_tax_rate,
    coalesce(p_is_takeout, false), p_notes, 'draft',
    v_print_area_code
  )
  returning id into v_item_id;

  perform public.fn_recalc_order_totals(p_order_id);
  return v_item_id;
end;
$$;
