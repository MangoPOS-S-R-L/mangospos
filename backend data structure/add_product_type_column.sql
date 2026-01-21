-- Add product_type column to menu_items table
ALTER TABLE menu_items 
ADD COLUMN product_type TEXT CHECK (product_type IN ('Comida', 'Bebida', 'Combo'));

-- Optional: Set default value for existing records if needed, e.g., 'Comida'
-- UPDATE menu_items SET product_type = 'Comida' WHERE product_type IS NULL;
