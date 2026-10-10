-- =============================================================================
-- 20261010_0002 — Confirmar a cocina SOLO las líneas de una comanda ya impresa
-- =============================================================================
--
-- Sin red, «Enviar» imprime la comanda por la LAN y encola
-- 'confirm_local_order' con los ids impresos (item_ids_by_area). Al volver la
-- red, el replay llamaba fn_confirm_order_to_kitchen(p_order_id), que pasa a
-- 'pending' TODAS las líneas en borrador de la orden: también las agregadas
-- después de imprimir. Esas quedaban «enviadas» sin haber salido a cocina, y
-- nadie volvía a mandarlas.
--
-- fn_confirm_order_items_to_kitchen confirma solo [p_item_ids] (borradores de
-- esa orden), con la fila de la orden bloqueada. Como la función de siempre,
-- marca la orden enviada (trg_orders_no_kitchen_resurrect sigue impidiendo que
-- una orden cerrada vuelva a 'sent_to_kitchen') y recalcula el consumo de
-- inventario (consume_inventory_from_order es idempotente). NO imprime ni
-- genera trabajos de impresión: la comanda ya salió por la LAN.
--
-- Devuelve cuántas líneas confirmó. Repetirla no cambia nada (0). Ids de otra
-- orden o que ya no están en borrador se ignoran.
--
-- No modifica fn_confirm_order_to_kitchen (la base viva difiere del repo).
-- La app la usa solo en el replay y, sin esta migración (PGRST202), vuelve a
-- confirmar la orden entera como antes: se puede aplicar en cualquier orden
-- respecto de la app.
-- =============================================================================

begin;

create or replace function public.fn_confirm_order_items_to_kitchen(
  p_order_id uuid,
  p_item_ids uuid[]
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
  v_auth uuid := auth.uid();
  v_count integer := 0;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  select coalesce(ts.business_id, z.business_id)
    into v_business
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.zones z on z.id = dt.zone_id
  where o.id = p_order_id
  for update of o;

  if not found then
    return 0;
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

  if coalesce(cardinality(p_item_ids), 0) = 0 then
    return 0;
  end if;

  update public.order_items
     set status = 'pending'
   where order_id = p_order_id
     and id = any(p_item_ids)
     and status = 'draft';
  get diagnostics v_count = row_count;

  if v_count > 0 then
    update public.orders
       set status = 'sent',
           status_ext = 'sent_to_kitchen'
     where id = p_order_id;

    perform public.consume_inventory_from_order(p_order_id);
  end if;

  return v_count;
end;
$$;

revoke all on function public.fn_confirm_order_items_to_kitchen(uuid, uuid[]) from public, anon;
grant execute on function public.fn_confirm_order_items_to_kitchen(uuid, uuid[]) to authenticated, service_role;

comment on function public.fn_confirm_order_items_to_kitchen(uuid, uuid[]) is
  'Replay de una comanda impresa por la LAN: confirma a cocina solo esas líneas (borradores de la orden), con la orden bloqueada. No imprime. Ver migración 20261010_0002.';

commit;
