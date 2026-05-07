-- =============================================================================
-- Migration: tabla bank_accounts + payments.bank_account_id
-- Purpose : Permitir al admin configurar las cuentas bancarias del negocio
--           para que el cajero, al cobrar por transferencia, indique a cuál
--           cuenta llegó el dinero. Trazabilidad de transferencias entrantes
--           para reconciliación posterior.
--
-- Compat: la columna `bank_account_id` en payments es nullable; pagos
-- legacy (cash, card, transfer sin cuenta seleccionada) siguen funcionando
-- igual. La tabla `bank_accounts` empieza vacía; el admin las crea desde
-- Ajustes → Tipos de Pago → Transferencias.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.bank_accounts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  bank_name       text NOT NULL,
  account_number  text NOT NULL,
  account_holder  text,
  account_type    text NOT NULL DEFAULT 'corriente'
                  CHECK (account_type IN ('corriente', 'ahorro', 'otro')),
  currency        text NOT NULL DEFAULT 'DOP'
                  CHECK (currency IN ('DOP', 'USD', 'EUR')),
  alias           text,
  is_active       boolean NOT NULL DEFAULT true,
  sort_order      integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.bank_accounts IS
  'Cuentas bancarias del negocio donde se reciben transferencias. El '
  'cajero las selecciona al cobrar para identificar el destino. Texto '
  'libre en bank_name para soportar bancos pequeños / billeteras digitales.';

COMMENT ON COLUMN public.bank_accounts.bank_name IS
  'Banco al que pertenece la cuenta (texto libre: "Banreservas", "BHD", '
  '"TPago", "Yappi", etc.).';
COMMENT ON COLUMN public.bank_accounts.account_holder IS
  'Titular registrado en el banco. Sale impreso en el ticket cuando se '
  'cobra para que el cliente sepa exactamente a quién está transfiriendo.';
COMMENT ON COLUMN public.bank_accounts.alias IS
  'Nombre amigable para que el cajero identifique rápido la cuenta '
  '("Cuenta principal", "Delivery", "Dólares").';

CREATE INDEX IF NOT EXISTS idx_bank_accounts_business
  ON public.bank_accounts(business_id);
CREATE INDEX IF NOT EXISTS idx_bank_accounts_active
  ON public.bank_accounts(business_id, is_active, sort_order)
  WHERE is_active = true;

-- ─── RLS ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.bank_accounts ENABLE ROW LEVEL SECURITY;

-- Members del negocio ven sus cuentas (cajeros, meseros, admins).
DROP POLICY IF EXISTS "bank_accounts_select_members" ON public.bank_accounts;
CREATE POLICY "bank_accounts_select_members" ON public.bank_accounts
  FOR SELECT USING (public.is_member_of_business(business_id));

-- Solo admins crean / editan / eliminan.
DROP POLICY IF EXISTS "bank_accounts_insert_admins" ON public.bank_accounts;
CREATE POLICY "bank_accounts_insert_admins" ON public.bank_accounts
  FOR INSERT WITH CHECK (public.is_admin_of_business(business_id));

DROP POLICY IF EXISTS "bank_accounts_update_admins" ON public.bank_accounts;
CREATE POLICY "bank_accounts_update_admins" ON public.bank_accounts
  FOR UPDATE USING (public.is_admin_of_business(business_id));

DROP POLICY IF EXISTS "bank_accounts_delete_admins" ON public.bank_accounts;
CREATE POLICY "bank_accounts_delete_admins" ON public.bank_accounts
  FOR DELETE USING (public.is_admin_of_business(business_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.bank_accounts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.bank_accounts TO service_role;

-- Trigger para updated_at automático
CREATE OR REPLACE FUNCTION public.fn_bank_accounts_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bank_accounts_updated_at ON public.bank_accounts;
CREATE TRIGGER trg_bank_accounts_updated_at
  BEFORE UPDATE ON public.bank_accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_bank_accounts_touch_updated_at();

-- ─── payments.bank_account_id ────────────────────────────────────────────────

ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS bank_account_id uuid
    REFERENCES public.bank_accounts(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.payments.bank_account_id IS
  'Cuenta bancaria a la que llegó la transferencia. NULL para pagos en '
  'efectivo/tarjeta o transferencias hechas antes de configurar bancos. '
  'ON DELETE SET NULL: borrar una cuenta no destruye el historial de '
  'pagos hechos a ella.';

CREATE INDEX IF NOT EXISTS idx_payments_bank_account
  ON public.payments(bank_account_id)
  WHERE bank_account_id IS NOT NULL;
