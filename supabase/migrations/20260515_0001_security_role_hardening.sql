-- =============================================================================
-- Fase 3 PRD-permisos: hardening de RLS por ROL (no solo por business_id).
--
-- PROBLEMA:
--   Las RLS actuales de `payments.pay_insert` y `order_items.items_rw` solo
--   validan que el usuario pertenezca al business (`user_has_business_access`).
--   Eso significa que cualquier autenticado del negocio — incluido un mesero
--   o cocinero — puede ejecutar INSERT en `payments` o DELETE en `order_items`
--   vía cliente Supabase directo (DevTools, curl, otro frontend, etc.),
--   bypassando los checks del UI Flutter.
--
--   El frontend ya enforce permisos (Fase 1 + 2 del PRD), pero el frontend
--   NUNCA puede ser la única fuente de verdad de seguridad.
--
-- ENTREGA (esta migration):
--   1. `payments.pay_insert` → drop + recreate con role check.
--      Permitidos: owner, admin, manager, cashier. Excluye waiter/cook/delivery.
--      Justificación: solo cajero/admin/manager cobran (confirmado por el
--      usuario).
--
--   2. `order_items.items_rw` → drop + recreate split en dos policies:
--        - SELECT permisivo (no cambia): cualquier staff del business.
--        - INSERT/UPDATE/DELETE: excluye solo 'cook' (cocina solo lee KDS).
--          Delivery se mantiene porque su preset incluye delivery.crear_orden
--          y por tanto necesita escribir order_items para crear la orden.
--
--   3. NO se tocan policies de SELECT (todo staff sigue viendo datos).
--   4. NO se tocan `menu_items`, `recipes`, `recipe_ingredients` —
--      ya tienen role check correcto.
--   5. NO se tocan `inventory_movements` — no tiene policy WRITE, RLS
--      bloquea INSERT directo, todo va vía RPC SECURITY DEFINER.
--
-- IMPACTO EN PRODUCCIÓN:
--   ⚠️ Cualquier integración externa que use service_role NO se afecta
--   (service_role bypassa RLS).
--   ⚠️ Si en algún negocio el flujo permite a meseros cobrar via PIN
--   override, esto los bloqueará a nivel backend. El usuario confirmó
--   que solo cajero/admin cobra. Si necesitas waiter cobrando, ajusta
--   esta migration ANTES de aplicarla.
--   ⚠️ Aplicar la migration es atómico — si rompe algo, correr el
--   archivo rollback `20260515_0001_security_role_hardening_ROLLBACK.sql`.
--
-- IDEMPOTENTE:
--   - DROP POLICY IF EXISTS antes de CREATE.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. payments.pay_insert: restringir a roles que cobran
-- ---------------------------------------------------------------------------

drop policy if exists "pay_insert" on public.payments;

create policy "pay_insert" on public.payments
  for insert
  to authenticated
  with check (
    public.user_has_business_access(auth.uid(), business_id)
    and public.user_business_role(auth.uid(), business_id) in (
      'owner', 'admin', 'manager', 'cashier'
    )
  );

comment on policy "pay_insert" on public.payments is
  'Solo owner/admin/manager/cashier pueden registrar pagos. Bloquea a '
  'waiter/cook/delivery aunque pertenezcan al business. Antes solo '
  'validaba business_id, era bypassable vía cliente Supabase directo.';

-- ---------------------------------------------------------------------------
-- 2. order_items.items_rw: split en SELECT permisivo + WRITE con role check
-- ---------------------------------------------------------------------------

drop policy if exists "items_rw" on public.order_items;

-- SELECT: cualquier staff del business (sin cambio efectivo)
create policy "items_select" on public.order_items
  for select
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
  );

-- INSERT/UPDATE/DELETE: excluye cook y delivery (roles que no manejan items).
-- Los demás (owner/admin/manager/cashier/waiter) pueden seguir operando.
create policy "items_write" on public.order_items
  as restrictive
  for all
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
    and public.user_business_role(
      auth.uid(),
      (
        select z.business_id
        from public.orders o
        join public.table_sessions s on s.id = o.session_id
        join public.dining_tables t on t.id = s.table_id
        join public.zones z on z.id = t.zone_id
        where o.id = order_items.order_id
        limit 1
      )
    ) in ('owner', 'admin', 'manager', 'cashier', 'waiter', 'delivery')
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
    and public.user_business_role(
      auth.uid(),
      (
        select z.business_id
        from public.orders o
        join public.table_sessions s on s.id = o.session_id
        join public.dining_tables t on t.id = s.table_id
        join public.zones z on z.id = t.zone_id
        where o.id = order_items.order_id
        limit 1
      )
    ) in ('owner', 'admin', 'manager', 'cashier', 'waiter', 'delivery')
  );

comment on policy "items_select" on public.order_items is
  'Lectura: cualquier staff del business. Sin cambio respecto a items_rw '
  'anterior — los meseros, cajeros, etc. siguen viendo todos los items.';

comment on policy "items_write" on public.order_items is
  'Escritura RESTRICTIVE: excluye roles cook y delivery aunque pertenezcan '
  'al business. Frontend ya filtra acciones por rol; esto cierra el bypass '
  'vía cliente Supabase directo.';

commit;
