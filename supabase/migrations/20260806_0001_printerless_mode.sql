-- =============================================================================
-- 20260806_0001 — Modo sin impresora (printerless)
-- =============================================================================
-- Permite que un negocio opere SIN impresoras termicas: en vez de mandar el
-- ticket al papel, la POS lo muestra en pantalla (con opcion de compartir PDF)
-- y ningun flujo se bloquea con "Impresora no configurada".
--
-- Alcance: flag por NEGOCIO. Cada dispositivo puede sobrescribirlo localmente
-- (SharedPreferences, ver lib/core/printing/printerless_mode.dart) — eso NO
-- vive en la base de datos porque depende del hardware de cada caja/tablet.
--
-- Sin efectos sobre datos existentes: default false = comportamiento actual.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists printerless_mode boolean not null default false;

comment on column public.business_settings.printerless_mode is
  'Modo sin impresora: si es true, la POS no exige impresoras. Facturas, '
  'precuentas, cierres y recibos de caja se muestran en pantalla (con '
  'compartir PDF) en vez de imprimirse. Cada dispositivo puede sobrescribir '
  'este valor localmente. Default false = comportamiento historico.';

commit;
