-- Database Schema Update for MangoPOS
-- This file contains the table definitions and functions for Customers, Cashier, and Kitchen modules.

-- ==========================================
-- 1. CUSTOMERS (Clientes)
-- ==========================================

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


-- ==========================================
-- 2. CASHIER (Caja)
-- ==========================================

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


-- ==========================================
-- 3. HELPER FUNCTIONS (Backend Logic)
-- ==========================================

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

-- ==========================================
-- 4. KITCHEN VIEW (Fixed Join)
-- ==========================================

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


-- ==========================================
-- 5. EMPLOYEES (Fix RLS for self-lookup)
-- ==========================================

-- Allow employees to read their own record even if they are not in user_businesses
DO $$
BEGIN
    -- Check if table exists before trying to alter policy
    IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'employees') THEN
        DROP POLICY IF EXISTS "employees by business" ON employees;
        DROP POLICY IF EXISTS "employees by business or self" ON employees;
        
        CREATE POLICY "employees by business or self" ON employees
            FOR ALL USING (
                (EXTRACT(EPOCH FROM NOW()) > 0 AND fn_user_in_business(business_id)) -- keep existing logic
                OR 
                user_id = auth.uid() -- Allow self-lookup
            );
    END IF;
END $$;


-- ==========================================
-- 6. FIX ZONES & TABLES ACCESS (Critical for Employees)
-- ==========================================

-- 1. Update helper to trust employees table too
-- This ensures 'fn_user_in_business' returns true for employees
CREATE OR REPLACE FUNCTION fn_user_in_business(p_business_id uuid)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM user_businesses 
        WHERE business_id = p_business_id AND user_id = auth.uid()
    ) OR EXISTS (
        SELECT 1 FROM employees 
        WHERE business_id = p_business_id AND user_id = auth.uid()
    );
END;
$$;

-- 2. Update Policies for Zones (Select & Insert)
ALTER TABLE zones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "zones_select" ON zones;
CREATE POLICY "zones_select" ON zones
    FOR SELECT USING (fn_user_in_business(business_id));

DROP POLICY IF EXISTS "zones_insert" ON zones;
CREATE POLICY "zones_insert" ON zones
    FOR INSERT WITH CHECK (fn_user_in_business(business_id));

DROP POLICY IF EXISTS "zones_modify" ON zones;
CREATE POLICY "zones_modify" ON zones
    FOR ALL USING (fn_user_in_business(business_id));

-- 3. Update Policies for Dining Tables
ALTER TABLE dining_tables ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tables_select" ON dining_tables;
CREATE POLICY "tables_select" ON dining_tables
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM zones z 
            WHERE z.id = dining_tables.zone_id 
            AND fn_user_in_business(z.business_id)
        )
    );

DROP POLICY IF EXISTS "tables_insert" ON dining_tables;
CREATE POLICY "tables_insert" ON dining_tables
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM zones z 
            WHERE z.id = dining_tables.zone_id 
            AND fn_user_in_business(z.business_id)
        )
    );

DROP POLICY IF EXISTS "tables_modify" ON dining_tables;
CREATE POLICY "tables_modify" ON dining_tables
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM zones z 
            WHERE z.id = dining_tables.zone_id 
            AND fn_user_in_business(z.business_id)
        )
    );


-- ==========================================
-- 7. FIX MENUS & ORDERS ACCESS (Critical for Employees)
-- ==========================================

-- MENUS
ALTER TABLE menus ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "menus_access" ON menus;
CREATE POLICY "menus_access" ON menus
    FOR ALL USING (fn_user_in_business(business_id));

-- CATEGORIES
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "categories_access" ON categories;
CREATE POLICY "categories_access" ON categories
    FOR ALL USING (fn_user_in_business(business_id));

-- MENU ITEMS
ALTER TABLE menu_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "menu_items_access" ON menu_items;
CREATE POLICY "menu_items_access" ON menu_items
    FOR ALL USING (fn_user_in_business(business_id));

-- MODIFIER GROUPS
ALTER TABLE modifier_groups ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "modifier_groups_access" ON modifier_groups;
CREATE POLICY "modifier_groups_access" ON modifier_groups
    FOR ALL USING (fn_user_in_business(business_id));

-- MODIFIERS
ALTER TABLE modifiers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "modifiers_access" ON modifiers;
CREATE POLICY "modifiers_access" ON modifiers
    FOR ALL USING (fn_user_in_business(business_id));

-- TABLE SESSIONS
-- (Now using table_id relations to validate business access)
ALTER TABLE table_sessions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "sessions_access" ON table_sessions;
CREATE POLICY "sessions_access" ON table_sessions
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM dining_tables t
            JOIN zones z ON t.zone_id = z.id
            WHERE t.id = table_sessions.table_id
            AND fn_user_in_business(z.business_id)
        )
    );

-- ORDERS
-- (Using session_id -> table -> zone -> business)
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "orders_access" ON orders;
CREATE POLICY "orders_access" ON orders
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM table_sessions s
            JOIN dining_tables t ON s.table_id = t.id
            JOIN zones z ON t.zone_id = z.id
            WHERE s.id = orders.session_id
            AND fn_user_in_business(z.business_id)
        )
    );

-- ORDER ITEMS
-- (Using order_id -> session -> table -> zone -> business)
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "order_items_access" ON order_items;
CREATE POLICY "order_items_access" ON order_items
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM orders o
            JOIN table_sessions s ON o.session_id = s.id
            JOIN dining_tables t ON s.table_id = t.id
            JOIN zones z ON t.zone_id = z.id
            WHERE o.id = order_items.order_id
            AND fn_user_in_business(z.business_id)
        )
    );


-- ==========================================
-- 8. FIX CASHIER ACCESS (Critical for Employees)
-- ==========================================

-- CASH REGISTERS
ALTER TABLE cash_registers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "cash_registers_access" ON cash_registers;
CREATE POLICY "cash_registers_access" ON cash_registers
    FOR ALL USING (fn_user_in_business(business_id));

-- CASH REGISTER SESSIONS
ALTER TABLE cash_register_sessions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "cash_sessions_access" ON cash_register_sessions;
CREATE POLICY "cash_sessions_access" ON cash_register_sessions
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM cash_registers cr
            WHERE cr.id = cash_register_sessions.cash_register_id
            AND fn_user_in_business(cr.business_id)
        )
    );

-- CASH TRANSACTIONS
ALTER TABLE cash_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "cash_transactions_access" ON cash_transactions;
CREATE POLICY "cash_transactions_access" ON cash_transactions
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM cash_register_sessions cs
            JOIN cash_registers cr ON cs.cash_register_id = cr.id
            WHERE cs.id = cash_transactions.session_id
            AND fn_user_in_business(cr.business_id)
        )
    );
