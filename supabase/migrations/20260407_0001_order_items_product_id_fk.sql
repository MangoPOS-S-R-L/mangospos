-- Add foreign key from order_items.product_id to menu_items.id
-- This enables Supabase PostgREST joins between order_items and menu_items.
ALTER TABLE "public"."order_items"
  ADD CONSTRAINT "order_items_product_id_fkey"
  FOREIGN KEY ("product_id")
  REFERENCES "public"."menu_items"("id")
  ON DELETE SET NULL;
