-- =============================================================================
-- Fix: sincronizar `orders.status` con `orders.status_ext`.
--
-- PROBLEMA:
--   `fn_close_order_and_table` actualiza solo `status_ext` (enum nuevo)
--   pero NO toca `status` (text viejo). Resultado: una orden pagada queda
--   con status_ext='paid' y status='sent', ensuciando reportes, KDS y la
--   vista de Productos sin cobrar.
--
--   Se detectó investigando un cierre de caja en mayo 2026: 2 órdenes de
--   750 efectivo tenían status='sent' aunque sus payments estaban
--   `completed`.
--
-- VOCABULARIOS:
--   - `status_ext` (enum order_status): open / sent_to_kitchen /
--     partially_paid / paid / void.
--   - `status` (text): open / sent / served / canceled / paid.
--
-- MAPEO al cerrar (`p_status` enum → `status` text):
--   - 'paid' → 'paid'
--   - 'void' → 'canceled'
--   - cualquier otro → no se toca status (caso no esperado pero defensivo).
--
-- ENTREGA:
--   1. Reemplaza `fn_close_order_and_table` para que sincronice ambos.
--   2. Backfill: corrige todas las órdenes con status_ext='paid' que
--      tengan status != 'paid'. Y status_ext='void' con status != 'canceled'.
--
-- IDEMPOTENTE: CREATE OR REPLACE + backfill seguro de re-correr.
-- =============================================================================

begin;

create or replace function public.fn_close_order_and_table(
  p_order_id uuid,
  p_status public.order_status
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session uuid;
  v_open_count int;
  v_table_id uuid;
  v_legacy_status text;
begin
  -- Mapeo enum → text legacy. Mantenemos compatibilidad con queries
  -- que aún leen `status` (KDS, reportes, etc.).
  v_legacy_status := case p_status
    when 'paid'::public.order_status then 'paid'
    when 'void'::public.order_status then 'canceled'
    else null
  end;

  update public.orders
  set status_ext = p_status,
      status     = coalesce(v_legacy_status, status),
      closed_at  = now()
  where id = p_order_id;

  select session_id into v_session from public.orders where id = p_order_id;
  select table_id into v_table_id from public.table_sessions where id = v_session;

  select count(*) into v_open_count
  from public.orders
  where session_id = v_session
    and closed_at is null
    and status_ext not in ('paid', 'void');

  if coalesce(v_open_count, 0) = 0 then
    update public.table_sessions
    set closed_at = now()
    where id = v_session and closed_at is null;

    if v_table_id is not null then
      update public.dining_tables
      set state = 'available'
      where id = v_table_id;
    end if;
  end if;
end;
$$;

comment on function public.fn_close_order_and_table(uuid, public.order_status) is
  'Cierra una orden actualizando status_ext (enum) Y status (text legacy) '
  'en sincronía. Si la sesión de mesa no tiene más órdenes abiertas, '
  'también libera la mesa.';

-- ---------------------------------------------------------------------------
-- Backfill: corrige órdenes históricas donde status quedó sin sincronizar.
-- ---------------------------------------------------------------------------

update public.orders
set status = 'paid'
where status_ext = 'paid'::public.order_status
  and status <> 'paid';

update public.orders
set status = 'canceled'
where status_ext = 'void'::public.order_status
  and status <> 'canceled';

commit;
