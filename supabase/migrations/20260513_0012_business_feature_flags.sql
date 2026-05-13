-- =============================================================================
-- Feature flags por negocio (2026-05-13).
--
-- PROBLEMA:
--   MangoPOS hoy asume restaurante con mesas + cocina + escáner. Los
--   negocios que NO son restaurantes (minimarkets, kioskos, panaderías,
--   barberías) tienen módulos visibles que no usan:
--     - Modos de venta (mesas, delivery, venta manual) inflando el
--       sidebar con opciones inútiles.
--     - Botón "Enviar a cocina" en un negocio sin cocina.
--     - Campo `barcode` en productos cuando el negocio no escanea.
--
-- SOLUCIÓN:
--   Flags booleanos en `business_settings` que el admin puede
--   prender/apagar desde Ajustes → Modos de negocio. Default TRUE para
--   preservar 100% el comportamiento actual: un negocio existente que
--   no toca nada sigue viéndose igual.
--
-- BACKWARDS-COMPATIBLE:
--   - Todas las columnas tienen default true.
--   - Si business_settings no tiene fila para el negocio, el código
--     Dart asume defaults (todo prendido).
--   - Nada existente lee estas columnas — la app las consulta cuando
--     implementemos los gates.
-- =============================================================================

begin;

-- Modos de venta — controla qué items aparecen en el sidebar de
-- /ventas. Si solo se quiere venta rápida, se apagan los otros 3.
-- (Self-service ya está hardcoded como disabled hoy, no le ponemos
-- flag.)
alter table public.business_settings
  add column if not exists sales_mode_table_enabled boolean default true not null;

alter table public.business_settings
  add column if not exists sales_mode_manual_enabled boolean default true not null;

alter table public.business_settings
  add column if not exists sales_mode_quick_enabled boolean default true not null;

alter table public.business_settings
  add column if not exists sales_mode_delivery_enabled boolean default true not null;

-- Cocina — cuando false:
--   * Se oculta el botón "Enviar a cocina" en el order screen.
--   * Al cobrar, los items se marcan automáticamente como `ready` sin
--     pasar por estado 'preparing'/'pending'.
--   * NO se imprimen comandas (ni se intenta encolar al cloud queue).
alter table public.business_settings
  add column if not exists kitchen_enabled boolean default true not null;

-- Código de barras — cuando false:
--   * Se oculta el campo `barcode` en el formulario de producto.
--   * Se oculta el botón/input de escaneo en el POS (cuando exista).
--   * Las búsquedas por barcode siguen funcionando si el dato existe en
--     BD (data legacy), pero la UI no expone la funcionalidad.
alter table public.business_settings
  add column if not exists barcode_enabled boolean default true not null;

comment on column public.business_settings.sales_mode_table_enabled is
  'Cuando false, oculta "Por zona" del sidebar de ventas. Negocios sin '
  'servicio de mesa (minimarket, take-away) no necesitan este modo.';

comment on column public.business_settings.sales_mode_quick_enabled is
  'Cuando false, oculta "Venta rápida". Default true porque casi todos '
  'los negocios la usan al menos como fallback.';

comment on column public.business_settings.kitchen_enabled is
  'Cuando false, no hay "Enviar a cocina": los items se marcan ready al '
  'cobrar y NO se imprime comanda. Para tiendas / barberías donde los '
  'productos no requieren preparación.';

comment on column public.business_settings.barcode_enabled is
  'Cuando false, oculta el campo barcode en el formulario de producto y '
  'el escáner en el POS. Para negocios que venden por menú (no por SKU '
  'con código).';

commit;
