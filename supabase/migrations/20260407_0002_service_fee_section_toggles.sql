-- Agrega columnas para controlar en qué secciones se aplica la propina de ley (service fee).
-- Por defecto: zona (mesas) y manual = activado, venta rápida = desactivado.

ALTER TABLE business_settings
  ADD COLUMN IF NOT EXISTS service_fee_on_zone   boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS service_fee_on_manual  boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS service_fee_on_quick   boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN business_settings.service_fee_on_zone
  IS 'Aplicar propina de ley en ventas por zona (mesas / dine-in)';
COMMENT ON COLUMN business_settings.service_fee_on_manual
  IS 'Aplicar propina de ley en ventas manuales (mostrador / walk-in)';
COMMENT ON COLUMN business_settings.service_fee_on_quick
  IS 'Aplicar propina de ley en venta rápida (quick sale)';
