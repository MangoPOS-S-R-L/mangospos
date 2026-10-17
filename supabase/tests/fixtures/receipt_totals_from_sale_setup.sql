CREATE TABLE orders (
  id uuid PRIMARY KEY, delivery_fee numeric(12,2) NOT NULL DEFAULT 0,
  closed_at timestamptz DEFAULT now()
);
CREATE TABLE order_checks (id uuid PRIMARY KEY, order_id uuid, is_closed boolean DEFAULT true);
CREATE TABLE fiscal_documents (
  id uuid PRIMARY KEY, business_id uuid NOT NULL, order_id uuid NOT NULL,
  check_id uuid, ncf_type text NOT NULL DEFAULT 'B02', status text NOT NULL DEFAULT 'active',
  subtotal numeric(12,2) NOT NULL DEFAULT 0, taxable_amount numeric(12,2) NOT NULL DEFAULT 0,
  itbis_amount numeric(12,2) NOT NULL DEFAULT 0, service_fee numeric(12,2) NOT NULL DEFAULT 0,
  total numeric(12,2) NOT NULL DEFAULT 0
);
CREATE TABLE payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), order_id uuid NOT NULL, check_id uuid,
  fiscal_document_id uuid, amount numeric(12,2), change_amount numeric(12,2) DEFAULT 0,
  status text NOT NULL DEFAULT 'completed'
);
CREATE TABLE taxes (
  business_id uuid, name text, rate numeric, include_in_ecf boolean, is_active boolean DEFAULT true
);
CREATE TABLE sales_notes (id uuid PRIMARY KEY, order_id uuid, check_id uuid, status text DEFAULT 'active');
CREATE TABLE order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), order_id uuid NOT NULL, check_id uuid,
  status text NOT NULL DEFAULT 'paid', qty numeric DEFAULT 1, quantity numeric DEFAULT 1,
  unit_price numeric DEFAULT 0, tax_mode text DEFAULT 'inclusive', tax_rate numeric DEFAULT 28,
  subtotal numeric(12,2), tax numeric(12,2), discounts numeric(12,2) DEFAULT 0, total numeric(12,2)
);
CREATE TABLE order_item_modifiers (item_id uuid, qty numeric DEFAULT 1, price numeric DEFAULT 0);
CREATE FUNCTION test_assert(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', message; END IF;
  RAISE NOTICE 'OK: %', message;
END;
$$;
INSERT INTO taxes VALUES
  ('10000000-0000-0000-0000-000000000001', 'ITBIS', 18, true, true),
  ('10000000-0000-0000-0000-000000000001', 'Ley', 10, false, true);
