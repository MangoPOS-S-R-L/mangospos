-- =============================================================================
-- ROLLBACK 20260602_0002 — Restaura el CHECK de business_type sin verticales retail
-- =============================================================================
--
-- Vuelve a la lista previa (sin Colmado, Tienda / Minimarket, Licoreria).
--
-- ⚠️ Si ya se registraron negocios con esos valores, este rollback FALLARÁ al
-- recrear el constraint (filas violan el CHECK). En ese caso, primero migra/
-- reasigna esos business_type (p.ej. a 'Tienda de Conveniencia' o 'Otro') y
-- luego corre este rollback.
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
        'Otro'
      ]
    )
  );
