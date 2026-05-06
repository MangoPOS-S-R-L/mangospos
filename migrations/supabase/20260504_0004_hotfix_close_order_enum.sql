-- HOTFIX: la migración 0003 agregó `when 'cancelled' then ...` dentro de
-- un CASE sobre `p_status` (tipo enum `order_status`). El enum no contiene
-- el valor 'cancelled', y postgres intenta castear el literal en cada
-- WHEN a tiempo de ejecución → la función falla con
-- "invalid input value for enum order_status: 'cancelled'" para CUALQUIER
-- llamada (incluso paid o void). Resultado: cobros y anulaciones rotos.
--
-- Fix: quitar la rama 'cancelled' del CASE. El enum solo soporta:
-- open, sent_to_kitchen, partially_paid, paid, void.

begin;

create or replace function public.fn_close_order_and_table(
  p_order_id uuid,
  p_status   public.order_status
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_session uuid;
  v_open_count int;
  v_table_id uuid;
  v_item_target public.item_status;
begin
  -- Cerrar la orden
  update public.orders
     set status_ext = p_status,
         closed_at  = now()
   where id = p_order_id;

  -- Mapear status de orden -> status de item para marcar items vivos
  -- Solo enums válidos en order_status: open, sent_to_kitchen, partially_paid, paid, void.
  v_item_target := case p_status
    when 'paid' then 'paid'::public.item_status
    when 'void' then 'void'::public.item_status
    else null
  end;

  if v_item_target is not null then
    update public.order_items
       set status = v_item_target
     where order_id = p_order_id
       and status not in ('paid'::public.item_status, 'void'::public.item_status);
  end if;

  -- Resolver session y table
  select session_id into v_session  from public.orders         where id = p_order_id;
  select table_id   into v_table_id from public.table_sessions where id = v_session;

  -- Si no hay más órdenes abiertas en la sesión, cerrar sesión y mesa
  select count(*) into v_open_count
    from public.orders
   where session_id = v_session
     and closed_at is null
     and status_ext not in ('paid', 'void');

  if coalesce(v_open_count, 0) = 0 then
    update public.table_sessions
       set closed_at = now()
     where id = v_session
       and closed_at is null;

    if v_table_id is not null then
      update public.dining_tables
         set state = 'available'
       where id = v_table_id;
    end if;
  end if;
end;
$$;

commit;

-- =============================================================================
-- Smoke check
-- =============================================================================
-- Probar el RPC con un order válido (lo hace el cobro normal):
-- select public.fn_close_order_and_table('<order_id>', 'paid');
-- Debe retornar void sin error y dejar items 'paid'.
