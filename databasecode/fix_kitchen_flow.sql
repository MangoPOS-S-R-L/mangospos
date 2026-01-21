-- ================================================================
-- FIX KITCHEN FLOW
-- 1. Drop the auto-kitchen trigger (it sends items too early).
-- 2. Ensure default status is 'draft'.
-- 3. Create RPC to explicitly send items to kitchen (Pedir).
-- ================================================================

-- 1. Drop the trigger if it exists
DROP TRIGGER IF EXISTS trg_auto_kitchen ON order_items;
DROP FUNCTION IF EXISTS fn_auto_send_to_kitchen;

-- 2. Set default status to 'draft'
ALTER TABLE order_items ALTER COLUMN status SET DEFAULT 'draft';

-- 3. Create function to "Fire" the order to the kitchen
CREATE OR REPLACE FUNCTION fn_confirm_order_to_kitchen(p_order_id UUID)
RETURNS VOID AS $$
BEGIN
    UPDATE order_items
    SET status = 'pending'
    WHERE order_id = p_order_id
      AND (status = 'draft' OR status IS NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
