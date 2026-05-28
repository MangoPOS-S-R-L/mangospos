-- ============================================================================
-- 20260528_0001 — business_settings.discount_display_mode
-- ============================================================================
--
-- Permite que cada negocio elija cómo se presenta el descuento en facturas
-- (modal del historial de ventas + ticket impreso de reimpresión):
--
--   'pre_discount'  → modo A (default). Subtotal pre-descuento, ITBIS al %
--                     real del subtotal, descuento como línea sustractiva.
--                     Math: subtotal + ITBIS − descuento = total.
--                     Matches el ticket impreso histórico.
--
--   'post_discount' → modo B. Subtotal derivado del total post-descuento
--                     (total / (1 + tasa)), ITBIS recomputado, descuento
--                     mostrado como nota informativa (no entra al sum).
--                     Math: subtotal + ITBIS = total; descuento es contexto.
--
-- Default 'pre_discount' preserva el comportamiento actual para todos los
-- negocios existentes. Es safe deploy: ningún path lee este valor antes de
-- que se aplique la migración (Flutter cae al default si la columna no
-- existe todavía o si la query falla).
-- ============================================================================

begin;

alter table public.business_settings
  add column if not exists discount_display_mode text default 'pre_discount';

-- Normaliza filas existentes que pudieran tener valores fuera del enum
-- soportado (defensa contra escrituras ad-hoc o migraciones futuras).
update public.business_settings
set discount_display_mode = 'pre_discount'
where discount_display_mode is null
   or discount_display_mode not in ('pre_discount', 'post_discount');

alter table public.business_settings
  alter column discount_display_mode set default 'pre_discount',
  alter column discount_display_mode set not null;

comment on column public.business_settings.discount_display_mode is
  'Modo de presentación del descuento en facturas. '
  '''pre_discount'' (default): subtotal pre-descuento, ITBIS al % real, '
  'descuento como línea sustractiva. '
  '''post_discount'': subtotal derivado del total post-descuento, ITBIS '
  'recomputado, descuento como nota informativa.';

commit;
