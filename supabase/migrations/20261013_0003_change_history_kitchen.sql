-- =============================================================================
-- 20261013_0003 — Historial: cada envío a cocina
-- =============================================================================
--
-- POR QUÉ. Pedido del dueño (2026-10-13): que en el historial se vea cuando
-- se mandan productos a cocina.
--
-- QUÉ. Una línea por envío (una ronda), no una por producto: «Juan Pérez
-- envió 3 productos de Mesa 5 a cocina» con la lista (cantidad, nombre,
-- modificadores y nota). El nombre es el mesero que digitó el producto con su
-- PIN (order_items.created_by_employee_id); si no hay, la cuenta logueada.
--
-- CÓMO. El envío de verdad es el paso de 'draft' a otro estado dentro de
-- fn_confirm_order_to_kitchen o fn_confirm_order_items_to_kitchen (la marca
-- kitchen_sent_at la pone la app DESPUÉS y es best-effort). El trigger va en
-- order_items con WHEN estrecho (solo cuando un borrador cambia de estado) y
-- además mira la pila de llamadas: pagar una venta rápida, anular o dividir
-- también sacan ítems de 'draft' y eso no es un envío.
--
-- SEGURIDAD. Igual que 0001/0002: si falla, avisa con WARNING y el envío
-- sigue. Desde ahora (las rondas viejas siguen en el reporte de Comandas).
--
-- REQUIERE 20261013_0002. IDEMPOTENTE.
-- ROLLBACK: 20261013_0003_change_history_kitchen_ROLLBACK.sql
-- Prueba: supabase/tests/change_history_operations_local_test.sh
-- =============================================================================

begin;

set local lock_timeout = '5s';

do $$
begin
  if to_regprocedure('private.fn_change_history_add(uuid, text, text, text, text, text, uuid, uuid, jsonb, timestamptz)') is null then
    raise exception 'Falta 20261013_0002_change_history_operations.sql';
  end if;
end;
$$;

create or replace function public.fn_change_history_on_kitchen_send()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row      jsonb := to_jsonb(new);
  v_business uuid;
  v_employee uuid := (to_jsonb(new) ->> 'created_by_employee_id')::uuid;
  v_name     text;
  v_mods     text;
  v_notes    text;
  v_line     text;
  v_prev     record;
begin
  begin
    if not private.fn_change_history_called_from(
             'fn_confirm_order_to_kitchen|fn_confirm_order_items_to_kitchen') then
      return null;
    end if;

    select ts.business_id into v_business
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    where o.id = new.order_id;
    v_business := coalesce((v_row ->> 'business_id')::uuid, v_business);

    -- «2 × Hamburguesa + Queso extra (sin cebolla)»
    v_name := coalesce(nullif(v_row ->> 'product_name', ''),
                       (select m.name from public.menu_items m
                        where m.id = (v_row ->> 'product_id')::uuid),
                       'Producto');
    if to_regclass('public.order_item_modifiers') is not null then
      select string_agg(coalesce(to_jsonb(m) ->> 'name', ''), ', ')
        into v_mods
      from public.order_item_modifiers m
      where m.item_id = new.id;
    end if;
    -- Sin las marcas internas ([CORTESIA:…], [PROMO_AUTO:…], [DEAL:…]).
    v_notes := nullif(btrim(regexp_replace(coalesce(v_row ->> 'notes', ''),
                                           '\[[^\]]*\]', '', 'g')), '');
    v_line := concat(
      trim_scale(coalesce((v_row ->> 'qty')::numeric,
                          (v_row ->> 'quantity')::numeric, 1))::text,
      ' × ', v_name,
      case when nullif(v_mods, '') is not null then ' + ' || v_mods end,
      case when v_notes is not null then ' (' || v_notes || ')' end);

    -- Una ronda = una transacción: se juntan en una sola línea.
    select h.id, h.changes into v_prev
    from public.change_history h
    where h.business_id = v_business
      and h.table_name = 'kitchen_rounds'
      and h.row_id = new.order_id::text
      and h.txid = txid_current()
    order by h.id desc
    limit 1;

    if v_prev.id is null then
      perform private.fn_change_history_add(
        v_business, 'kitchen_rounds', new.order_id::text, 'create',
        private.fn_change_history_order_label(new.order_id), '',
        auth.uid(), v_employee,
        jsonb_build_object('event', 'kitchen_send', 'items_count', 1,
                           'products', jsonb_build_array(v_line)));
    else
      update public.change_history h
         set changes = h.changes || jsonb_build_object(
               'items_count', coalesce((h.changes ->> 'items_count')::int, 0) + 1,
               'products', coalesce(h.changes -> 'products', '[]'::jsonb)
                           || to_jsonb(v_line))
       where h.id = v_prev.id;
    end if;
  exception when others then
    raise warning 'fn_change_history_on_kitchen_send: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

revoke all on function public.fn_change_history_on_kitchen_send() from public, anon, authenticated;

drop trigger if exists trg_zz_change_history_kitchen on public.order_items;
create trigger trg_zz_change_history_kitchen
  after update of status on public.order_items
  for each row
  when (old.status::text = 'draft'
        and new.status::text not in ('draft', 'void'))
  execute function public.fn_change_history_on_kitchen_send();

commit;
