-- =============================================================================
-- 20260602_0002 — Verticales retail en businesses.business_type (R0)
-- =============================================================================
--
-- Amplía el CHECK de `business_type` con los verticales retail del PRD de
-- extensión: Colmado, Tienda / Minimarket y Licoreria. Aditivo y seguro: solo
-- agrega valores permitidos; ningún negocio existente cambia.
--
-- El preset de feature flags por vertical (mostrador, sin mesas/cocina, con
-- escaneo e inventario básico) lo aplica la app al registrar — ver
-- lib/core/business/retail_profile_defaults.dart. Esta migración NO toca
-- business_settings ni gatea nada por sí sola.
--
-- Convención de valores: sin acentos en dbValue (igual que 'Comida Rapida',
-- 'Cafeteria / Panaderia'); el label con acentos vive en el catálogo de la UI.
-- Ver docs/PRD_RETAIL_EXTENSION.md (fase R0).
-- =============================================================================

alter table public.businesses
  drop constraint if exists businesses_business_type_check;

alter table public.businesses
  add constraint businesses_business_type_check
  check (
    business_type is null
    or business_type = any (
      array[
        'Restaurante',
        'Comida Rapida',
        'Cafeteria / Panaderia',
        'Bar / Lounge',
        'Heladeria / Postres',
        'Solo Delivery',
        'Tienda de Conveniencia',
        'Bar de Jugos / Comida Saludable',
        'Food Truck',
        'Colmado',
        'Tienda / Minimarket',
        'Licoreria',
        'Otro'
      ]
    )
  );
