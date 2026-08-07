-- =============================================================================
-- 20260806_0001 — Modo sin impresora (printerless)
-- =============================================================================
-- Permite que un negocio opere SIN impresoras termicas: en vez de mandar el
-- ticket al papel, la POS lo muestra en pantalla (con opcion de compartir PDF)
-- y ningun flujo se bloquea con "Impresora no configurada".
--
-- Son DOS flags independientes porque el caso comun no es todo-o-nada: un
-- restaurante con impresora en caja pero cocina solo con pantallas KDS quiere
-- seguir imprimiendo facturas y apagar unicamente las comandas.
--   - printerless_mode    → documentos de caja (factura, precuenta, cierre,
--                           recibos de movimiento). Cada dispositivo puede
--                           sobrescribirlo localmente (SharedPreferences, ver
--                           lib/core/printing/printerless_mode.dart) porque
--                           depende del hardware de esa caja/tablet.
--   - printerless_kitchen → comandas de cocina. SIN override por dispositivo:
--                           la impresora de cocina es compartida, que una
--                           tablet de mesero no tenga impresora no significa
--                           que la cocina no deba recibir su comanda.
--
-- Sin efectos sobre datos existentes: default false = comportamiento actual.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists printerless_mode boolean not null default false;

alter table public.business_settings
  add column if not exists printerless_kitchen boolean not null default false;

comment on column public.business_settings.printerless_mode is
  'Modo sin impresora para documentos de CAJA: si es true, facturas, '
  'precuentas, cierres y recibos de movimiento se muestran en pantalla (con '
  'compartir PDF) en vez de imprimirse, y nada se bloquea por falta de '
  'impresora. No afecta las comandas (ver printerless_kitchen). Cada '
  'dispositivo puede sobrescribir este valor localmente. Default false = '
  'comportamiento historico.';

comment on column public.business_settings.printerless_kitchen is
  'Modo sin impresora para COMANDAS: si es true, los envios a cocina no '
  'imprimen papel ni exigen impresora asignada — los pedidos llegan al KDS. '
  'No abre ventana en pantalla en cada envio. Sin override por dispositivo. '
  'Default false = comportamiento historico.';

commit;

-- PostgREST cachea el esquema: sin esto la app sigue viendo PGRST204 aunque
-- las columnas ya existan.
notify pgrst, 'reload schema';
