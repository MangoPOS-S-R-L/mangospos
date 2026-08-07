-- =============================================================================
-- ROLLBACK 20260806_0001 — Modo sin impresora (printerless)
-- =============================================================================
-- Quita las columnas de los flags. No afecta datos de venta: es solo
-- configuracion. Los overrides por dispositivo viven en SharedPreferences y
-- quedan inertes (la app cae al default `false` si la columna no existe).
-- =============================================================================

begin;

alter table public.business_settings
  drop column if exists printerless_mode;

alter table public.business_settings
  drop column if exists printerless_kitchen;

commit;

notify pgrst, 'reload schema';
