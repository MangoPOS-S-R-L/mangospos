-- =============================================================================
-- ROLLBACK de 20260803_0001_rls_honor_app_permissions.sql
--
-- Quita las policies aditivas y la función puente. Al ser aditivas, soltarlas
-- devuelve el acceso a exactamente lo que era antes (owner/admin vía las
-- policies originales) sin tocar nada más.
--
-- OJO: tras esto, borrar insumos con un rol no-admin vuelve a fallar EN
-- SILENCIO desde el lado base de datos. La app ya no reporta un falso éxito
-- (ver `InventoryWriteDeniedException` en inventory_repository.dart), pero la
-- operación seguirá sin poder hacerse.
-- =============================================================================

begin;

drop policy if exists "ii_write_by_permission" on public.inventory_items;
drop policy if exists "printers_write_by_permission" on public.printers;
drop policy if exists "print_areas_write_by_permission" on public.print_areas;
drop policy if exists "print_area_printers_write_by_permission"
  on public.print_area_printers;

drop function if exists public.user_has_business_permission(uuid, text);

commit;
