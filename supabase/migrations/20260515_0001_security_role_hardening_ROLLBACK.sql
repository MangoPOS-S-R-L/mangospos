-- =============================================================================
-- ROLLBACK de `20260515_0001_security_role_hardening.sql`.
--
-- Restaura las policies originales (solo business_id, sin role check) en
-- caso de que el hardening rompa algún flujo en producción.
--
-- Cuándo correrlo:
--   - Si alguien con rol owner/admin/manager/cashier ve "permission denied"
--     al cobrar y no logras identificar la causa.
--   - Si meseros legítimos no pueden agregar/editar items por algún caso
--     no contemplado (ej. negocio con flujo donde el mesero también cobra).
--
-- Después del rollback, investigá el problema y vuelve a aplicar la
-- migration forward cuando esté ajustada.
--
-- IDEMPOTENTE: DROP POLICY IF EXISTS antes de CREATE.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Revertir payments.pay_insert al estado original (solo business_id)
-- ---------------------------------------------------------------------------

drop policy if exists "pay_insert" on public.payments;

create policy "pay_insert" on public.payments
  for insert
  to authenticated
  with check (public.user_has_business_access(auth.uid(), business_id));

-- ---------------------------------------------------------------------------
-- 2. Revertir order_items: drop split policies, restaurar items_rw original
-- ---------------------------------------------------------------------------

drop policy if exists "items_select" on public.order_items;
drop policy if exists "items_write" on public.order_items;

create policy "items_rw" on public.order_items
  to authenticated
  using (
    exists (
      select 1
      from public.orders o
      join public.table_sessions s on s.id = o.session_id
      join public.dining_tables t on t.id = s.table_id
      join public.zones z on z.id = t.zone_id
      where o.id = order_items.order_id
        and z.business_id in (select public.current_user_business_ids())
    )
  )
  with check (
    exists (
      select 1
      from public.orders o
      join public.table_sessions s on s.id = o.session_id
      join public.dining_tables t on t.id = s.table_id
      join public.zones z on z.id = t.zone_id
      where o.id = order_items.order_id
        and z.business_id in (select public.current_user_business_ids())
    )
  );

commit;
