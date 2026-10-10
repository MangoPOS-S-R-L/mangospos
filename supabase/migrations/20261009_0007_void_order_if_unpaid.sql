-- =============================================================================
-- 20261009_0007 — Anulación automática solo si la venta sigue abierta y sin cobros
-- =============================================================================
--
-- El replay de `void_order` (cola offline y op-log del Hub) y el cierre de una
-- pestaña retail leían la orden y DESPUÉS llamaban a fn_close_order_and_table,
-- que no protege 'paid'. Si otra caja cobraba entre la lectura y el cierre, se
-- anulaba una venta cobrada. Tampoco se miraban los cobros parciales.
--
-- fn_void_order_if_unpaid hace la comprobación y el cierre en una sola
-- transacción, con la fila de la orden bloqueada. fn_process_payment_v3 bloquea
-- la misma fila y rechaza órdenes anuladas, así que cobro y anulación quedan en
-- fila: o se cobra primero y la anulación se omite, o se anula primero y el
-- cobro se rechaza (ORDER_ALREADY_CLOSED).
--
-- Devuelve 'voided', 'already_closed' (paid/void/cerrada), 'has_payments'
-- (cobro pending/completed, orden parcialmente pagada o ítems pagados) o
-- 'not_found'. Solo para anulaciones automáticas: la anulación explícita con
-- motivo (annulOrder) sigue su propio flujo y no cambia.
--
-- No modifica fn_close_order_and_table: la llama tal cual esté en la base.
-- Aplicar ANTES de publicar la app que la usa (la app recurre al camino viejo
-- si no la encuentra, PGRST202).
-- =============================================================================

begin;

create or replace function public.fn_void_order_if_unpaid(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status public.order_status;
  v_closed_at timestamptz;
  v_business uuid;
  v_auth uuid := auth.uid();
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  select o.status_ext, o.closed_at, coalesce(ts.business_id, z.business_id)
    into v_status, v_closed_at, v_business
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.zones z on z.id = dt.zone_id
  where o.id = p_order_id
  for update of o;

  if not found then
    return 'not_found';
  end if;

  -- Con JWT: solo alguien del negocio (fila directa, o dueño / usuario
  -- compartido entre sucursales). Sin JWT solo llega service_role.
  if v_auth is not null and not coalesce(
    exists (
      select 1 from public.user_businesses ub
      where ub.user_id = v_auth and ub.business_id = v_business
    )
    or v_business in (select public.current_user_business_ids()),
    false
  ) then
    raise exception 'NOT_A_MEMBER';
  end if;

  if v_closed_at is not null
     or v_status in ('paid'::public.order_status, 'void'::public.order_status) then
    return 'already_closed';
  end if;

  if v_status = 'partially_paid'::public.order_status
     or exists (
       select 1 from public.payments p
       where p.order_id = p_order_id
         and p.status in ('pending', 'completed')
     )
     or exists (
       -- Como texto: supabase/schema.sql no lista 'paid' en item_status
       -- (el cobro sí lo usa en la base viva); así nunca falla por el enum.
       select 1 from public.order_items oi
       where oi.order_id = p_order_id
         and oi.status::text = 'paid'
     ) then
    return 'has_payments';
  end if;

  perform public.fn_close_order_and_table(p_order_id, 'void'::public.order_status);
  return 'voided';
end;
$$;

revoke all on function public.fn_void_order_if_unpaid(uuid) from public, anon;
grant execute on function public.fn_void_order_if_unpaid(uuid) to authenticated, service_role;

comment on function public.fn_void_order_if_unpaid(uuid) is
  'Anulación automática (replay de void_order, cierre de pestaña retail): anula solo si la orden sigue abierta y sin cobros, con la fila bloqueada. annulOrder no la usa.';

commit;
