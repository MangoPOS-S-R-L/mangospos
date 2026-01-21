-- Run this script SECOND (after 01_fix_enum.sql)
-- This applies the Tables, RLS Policies, and Functions.

-- ================================================================
-- CUSTOMERS MODULE
-- ================================================================
CREATE TABLE IF NOT EXISTS customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL, 
    name TEXT NOT NULL,
    phone TEXT,
    email TEXT,
    address TEXT,
    tax_id TEXT, 
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE customers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users with matching business_id" ON customers;
CREATE POLICY "Enable all access for authenticated users with matching business_id" ON customers
    FOR ALL
    USING (auth.uid() IN (
        SELECT user_id FROM user_businesses WHERE business_id = customers.business_id
    ));

-- ================================================================
-- CASHIER MODULE
-- ================================================================
CREATE TABLE IF NOT EXISTS cash_registers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL,
    name TEXT NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE cash_registers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Access cash_registers based on business_id" ON cash_registers;
CREATE POLICY "Access cash_registers based on business_id" ON cash_registers
    FOR ALL USING (auth.uid() IN (
        SELECT user_id FROM user_businesses WHERE business_id = cash_registers.business_id
    ));

CREATE TABLE IF NOT EXISTS cash_register_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cash_register_id UUID REFERENCES cash_registers(id) NOT NULL,
    user_id UUID REFERENCES auth.users(id) NOT NULL,
    opened_at TIMESTAMPTZ DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    start_amount NUMERIC(15, 2) DEFAULT 0.00,
    end_amount NUMERIC(15, 2), 
    difference NUMERIC(15, 2) DEFAULT 0.00,
    status TEXT DEFAULT 'open', 
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE cash_register_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Access sessions based on cash_register business" ON cash_register_sessions;
CREATE POLICY "Access sessions based on cash_register business" ON cash_register_sessions
    FOR ALL USING (
        cash_register_id IN (
            SELECT id FROM cash_registers WHERE business_id IN (
                SELECT business_id FROM user_businesses WHERE user_id = auth.uid()
            )
        )
    );

CREATE TABLE IF NOT EXISTS cash_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID REFERENCES cash_register_sessions(id) NOT NULL,
    amount NUMERIC(15, 2) NOT NULL,
    type TEXT NOT NULL, 
    description TEXT,
    related_order_id UUID, 
    created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE cash_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Access transactions via sessions" ON cash_transactions;
CREATE POLICY "Access transactions via sessions" ON cash_transactions
    FOR ALL USING (
        session_id IN (
             SELECT id FROM cash_register_sessions WHERE cash_register_id IN (
                SELECT id FROM cash_registers WHERE business_id IN (
                    SELECT business_id FROM user_businesses WHERE user_id = auth.uid()
                )
             )
        )
    );

-- ================================================================
-- CASHIER FUNCTIONS
-- ================================================================
CREATE OR REPLACE FUNCTION fn_open_cash_session(
    p_cash_register_id UUID,
    p_user_id UUID,
    p_start_amount NUMERIC
) RETURNS JSONB AS $$
DECLARE
    v_session_id UUID;
    v_existing_open UUID;
BEGIN
    SELECT id INTO v_existing_open FROM cash_register_sessions
    WHERE cash_register_id = p_cash_register_id AND status = 'open';

    IF v_existing_open IS NOT NULL THEN
        RETURN jsonb_build_object('error', 'Caja ya esta abierta', 'session_id', v_existing_open);
    END IF;

    INSERT INTO cash_register_sessions (cash_register_id, user_id, start_amount, status)
    VALUES (p_cash_register_id, p_user_id, p_start_amount, 'open')
    RETURNING id INTO v_session_id;

    INSERT INTO cash_transactions (session_id, amount, type, description)
    VALUES (v_session_id, p_start_amount, 'deposit', 'Apertura de caja');

    RETURN jsonb_build_object('success', true, 'session_id', v_session_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION fn_close_cash_session(
    p_session_id UUID,
    p_end_amount NUMERIC,
    p_notes TEXT
) RETURNS JSONB AS $$
DECLARE
    v_start_amount NUMERIC;
    v_total_sales NUMERIC;
    v_total_deposits NUMERIC;
    v_total_withdrawals NUMERIC;
    v_expected_amount NUMERIC;
    v_difference NUMERIC;
BEGIN
    SELECT start_amount INTO v_start_amount FROM cash_register_sessions WHERE id = p_session_id;

    SELECT COALESCE(SUM(amount), 0) INTO v_total_sales FROM cash_transactions WHERE session_id = p_session_id AND type = 'sale';
    SELECT COALESCE(SUM(amount), 0) INTO v_total_deposits FROM cash_transactions WHERE session_id = p_session_id AND type = 'deposit';
    SELECT COALESCE(SUM(amount), 0) INTO v_total_withdrawals FROM cash_transactions WHERE session_id = p_session_id AND type = 'withdrawal';

    v_expected_amount := (v_total_deposits + v_total_sales) - v_total_withdrawals;
    
    v_difference := p_end_amount - v_expected_amount;

    UPDATE cash_register_sessions
    SET closed_at = NOW(),
        end_amount = p_end_amount,
        difference = v_difference,
        status = 'closed',
        notes = p_notes
    WHERE id = p_session_id;

    RETURN jsonb_build_object('success', true, 'difference', v_difference, 'expected', v_expected_amount);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION fn_get_cash_session_summary(p_session_id UUID)
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'start_amount', s.start_amount,
        'opened_at', s.opened_at,
        'total_sales', (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type = 'sale'),
        'total_deposits', (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type = 'deposit'),
        'total_withdrawals', (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type = 'withdrawal')
    ) INTO v_result
    FROM cash_register_sessions s
    WHERE s.id = p_session_id;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ================================================================
-- KITCHEN FLOW & VIEW
-- ================================================================

-- Clean up any conflicting triggers
DROP TRIGGER IF EXISTS trg_auto_kitchen ON order_items;
DROP FUNCTION IF EXISTS fn_auto_send_to_kitchen;

-- Ensure default status is 'draft' for order_items
-- (Requires 'draft' to allow be present in Enum, checked by 01_fix_enum.sql)
ALTER TABLE order_items ALTER COLUMN status SET DEFAULT 'draft';

-- Function to manually confirm orders (Draft -> Pending)
CREATE OR REPLACE FUNCTION fn_confirm_order_to_kitchen(p_order_id UUID)
RETURNS VOID AS $$
BEGIN
    UPDATE order_items
    SET status = 'pending'
    WHERE order_id = p_order_id
      AND (status = 'draft' OR status IS NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Kitchen View (Corrected Join Logic)
CREATE OR REPLACE VIEW v_kitchen_items AS
SELECT 
    oi.id,
    oi.order_id,
    oi.product_id,
    mi.name AS product_name, 
    oi.qty,
    oi.status,
    oi.notes,
    oi.created_at,
    COALESCE(z.business_id, mi.business_id) AS business_id,
    dt.label AS table_name,
    z.name AS zone_name
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
LEFT JOIN menu_items mi ON oi.product_id = mi.id
LEFT JOIN table_sessions ts ON o.session_id = ts.id
LEFT JOIN dining_tables dt ON ts.table_id = dt.id
LEFT JOIN zones z ON dt.zone_id = z.id;
