-- =============================================================================
-- Un insumo nuevo entra SOLO a los conteos que están abiertos.
--
-- EL PROBLEMA:
--   `fn_physical_count_freeze` congela los insumos activos de ESE momento. Si
--   durante el conteo se marca un producto como "Inventariable" —o se da de
--   alta un insumo desde cualquier otra pantalla— la ficha nace fuera de la
--   sesión y no hay dónde anotar lo que hay en el anaquel. En un conteo a
--   ciegas es peor todavía: quien cuenta no ve el stock del sistema, así que
--   tampoco tiene forma de notar que ese renglón le falta.
--
-- POR QUÉ UN TRIGGER Y NO TOCAR `fn_menu_item_set_inventory_tracked`:
--   1. Esa función está reescrita sobre la definición VIVA (20260613_0002);
--      volver a tocarla es entrar en la zona donde el repo y la base
--      divergen, y es la que decide cómo consume el POS.
--   2. Un insumo nace por varios caminos: el switch de Inventariable, la
--      pantalla de Insumos, las transferencias entre negocios. El trigger los
--      cubre todos con una sola pieza.
--
-- QUÉ HACE: por cada sesión `in_progress` del MISMO negocio, agrega la línea
--   con el stock actual de la bodega de esa sesión (0 para una ficha recién
--   creada). Idempotente por el unique (session_id, item_id).
--
-- NUNCA BLOQUEA EL ALTA: si algo falla acá, el insumo se crea igual. Un
--   conteo abierto no puede ser motivo de que no se pueda dar de alta
--   mercancía; por eso el bloque `exception when others`.
--
-- LO QUE NO HACE, a propósito:
--   · Desactivar un insumo NO le saca la línea del conteo. Lo que se contó,
--     contado está.
--   · No toca sesiones en `draft`: esas todavía no congelaron y van a tomar
--     el catálogo completo cuando lo hagan.
--
-- REQUIERE: 20260516_0011 (tablas del conteo).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

create or replace function public.fn_inventory_item_join_open_counts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(new.is_active, true) then
    return new;
  end if;

  begin
    insert into public.physical_count_lines (
      session_id, item_id, snapshot_quantity
    )
    select
      s.id,
      new.id,
      coalesce(st.quantity, 0)
    from public.physical_count_sessions s
    left join public.inventory_stock st
      on st.item_id = new.id
     and st.warehouse_id = s.warehouse_id
    where s.business_id = new.business_id
      and s.status = 'in_progress'
    on conflict (session_id, item_id) do nothing;
  exception
    when others then
      -- El alta del insumo manda. Si esto falla, la pantalla del conteo
      -- igual puede sumarlo a mano (fn_physical_count_add_item).
      null;
  end;

  return new;
end;
$$;

comment on function public.fn_inventory_item_join_open_counts() is
  'Agrega el insumo a las sesiones de conteo in_progress de su negocio. '
  'Best-effort: nunca bloquea el alta del insumo.';

drop trigger if exists trg_inventory_items_join_open_counts
  on public.inventory_items;
create trigger trg_inventory_items_join_open_counts
  after insert on public.inventory_items
  for each row
  execute function public.fn_inventory_item_join_open_counts();

-- Reactivar un insumo apagado también lo mete al conteo en curso. El `when`
-- es lo que hace que esto sea gratis: `inventory_items` se ACTUALIZA seguido
-- (el costo se mueve en cada recepción de mercancía) y el trigger no tiene
-- por qué correr en esos updates.
drop trigger if exists trg_inventory_items_reactivated_join_open_counts
  on public.inventory_items;
create trigger trg_inventory_items_reactivated_join_open_counts
  after update on public.inventory_items
  for each row
  when (
    old.is_active is distinct from new.is_active
    and coalesce(new.is_active, true)
  )
  execute function public.fn_inventory_item_join_open_counts();

commit;
