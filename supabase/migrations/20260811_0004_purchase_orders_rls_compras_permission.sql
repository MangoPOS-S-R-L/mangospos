-- =============================================================================
-- PRD 6.1 · F2 — Órdenes de compra: escritura para quien tenga el permiso
-- `compras.acceso` (incluye manager en los roles del sistema).
--
-- CONTEXTO:
--   `po_write`/`poi_write` limitan la escritura a owner/admin, pero el PRD
--   mapea compras.crear_po también a manager, y el permiso `compras.acceso`
--   (20260514_0003) ya está concedido a owner/admin/manager. Se sigue el
--   patrón de 20260803_0001: policy ADITIVA vía el puente
--   `user_has_business_permission`, así el motor de permisos de la app manda
--   y las policies existentes quedan intactas (se combinan con OR).
--
-- IDEMPOTENTE / BACKWARDS-COMPATIBLE:
--   - Solo policies nuevas; owner/admin no pierden nada.
--   - Quitar el permiso a un rol en Configuración → Roles y Permisos vuelve
--     a cerrar la escritura sin tocar la base.
-- =============================================================================

begin;

drop policy if exists "po_write_compras" on public.purchase_orders;
create policy "po_write_compras" on public.purchase_orders
  to authenticated
  using (public.user_has_business_permission(business_id, 'compras.acceso'))
  with check (public.user_has_business_permission(business_id, 'compras.acceso'));

drop policy if exists "poi_write_compras" on public.purchase_order_items;
create policy "poi_write_compras" on public.purchase_order_items
  to authenticated
  using (
    exists (
      select 1 from public.purchase_orders po
      where po.id = purchase_order_items.purchase_order_id
        and public.user_has_business_permission(po.business_id, 'compras.acceso')
    )
  )
  with check (
    exists (
      select 1 from public.purchase_orders po
      where po.id = purchase_order_items.purchase_order_id
        and public.user_has_business_permission(po.business_id, 'compras.acceso')
    )
  );

commit;
