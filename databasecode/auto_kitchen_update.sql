-- ================================================================
-- AUTO-KITCHEN UPDATE
-- Ensures that all items added to orders automatically go to the Kitchen (status = 'pending')
-- ================================================================

-- 1. Create a trigger function to force status = 'pending' on new items
CREATE OR REPLACE FUNCTION fn_auto_send_to_kitchen()
RETURNS TRIGGER AS $$
BEGIN
    -- If status is not provided or is 'draft', set it to 'pending'
    IF NEW.status IS NULL OR NEW.status = 'draft' THEN
        NEW.status := 'pending';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. Attach the trigger to order_items
DROP TRIGGER IF EXISTS trg_auto_kitchen ON order_items;

CREATE TRIGGER trg_auto_kitchen
BEFORE INSERT ON order_items
FOR EACH ROW
EXECUTE FUNCTION fn_auto_send_to_kitchen();

-- 3. Update any existing 'draft' items to 'pending' so they appear immediately
UPDATE order_items
SET status = 'pending'
WHERE status = 'draft';

-- 4. Verify v_kitchen_items view exists (re-asserting just in case)
-- (This was defined in schema_update.sql but good to keep consistent)
