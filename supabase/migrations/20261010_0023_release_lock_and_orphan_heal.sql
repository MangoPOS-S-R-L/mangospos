-- =============================================================================
-- 20261010_0023 — Ninguna orden con productos queda colgada de una mesa cerrada
-- =============================================================================
--
-- POR QUÉ. Último camino conocido por el que una orden con productos
-- desaparecía del salón (pendiente 8 del 10-oct):
--   1. fn_release_empty_table (salir de una mesa sin productos) se serializaba
--      con un FOR UPDATE de la fila de la mesa, que NO excluye a fn_open_table
--      (esa no toca la fila si la mesa ya está ocupada; toma un candado
--      consultivo por mesa). Si alguien salía mientras otro entraba, la apertura
--      podía crear su orden en la sesión que la salida cerraba: orden viva en
--      sesión cerrada, invisible en el salón. Lo mismo puede pasar con un cobro
--      que cierra la mesa mientras otro la reabre.
--   2. El candado de ítems (20260819_0004/20261010_0020) solo miraba si la
--      ORDEN estaba cerrada: los productos entraban a la orden huérfana igual.
--
-- QUÉ CAMBIA.
--   1. fn_release_empty_table toma también el candado por mesa (antes del
--      FOR UPDATE, que se conserva). Cuerpo vivo del 10-oct, md5 5dc47a35…
--      (el mismo que restaura la reversa de T02). Única diferencia.
--   2. Candado de ítems: si la orden está viva pero su sesión cerrada, la
--      orden vuelve a su mesa (fn_reattach_orphan_order): mesa libre → se
--      reabre su sesión; mesa tomada por otra cuenta → pasa a esa sesión como
--      cuenta en revisión. El producto entra. Camino normal: la misma lectura
--      por PK (ahora con su sesión).
--
-- Salir de una mesa SIN productos sigue liberándola al instante (regla del
-- dueño); solo espera a una apertura que esté en curso en esa misma mesa.
--
-- IDEMPOTENTE. ROLLBACK: 20261010_0023_release_lock_and_orphan_heal_ROLLBACK.sql
-- Prueba local: supabase/tests/release_lock_and_orphan_heal_local_test.sh
-- =============================================================================

begin;

-- Orden viva colgada de una sesión cerrada: si la mesa está libre, se reabre
-- su sesión; si otra cuenta ya la tomó, la orden pasa a esa sesión como
-- cuenta en revisión (misma identidad). Bajo el candado de la mesa.
create or replace function public.fn_reattach_orphan_order(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_session        uuid;
  v_table          uuid;
  v_business       uuid;
  v_order_closed   timestamptz;
  v_session_closed timestamptz;
  v_status         public.order_status;
  v_other_session  uuid;
begin
  select o.session_id, ts.table_id, coalesce(ts.business_id, z.business_id),
         o.closed_at, ts.closed_at, o.status_ext
    into v_session, v_table, v_business, v_order_closed, v_session_closed, v_status
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where o.id = p_order_id
   for update of o;

  if not found or v_order_closed is not null or v_session_closed is null
     or v_table is null then
    return 'not_orphan';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_table::text, 0));

  -- Re-chequeo dentro del candado (snapshot nuevo).
  select ts.closed_at into v_session_closed
    from public.table_sessions ts where ts.id = v_session;
  if v_session_closed is null then
    return 'not_orphan';
  end if;

  select ts.id into v_other_session
    from public.table_sessions ts
   where ts.table_id = v_table
     and ts.closed_at is null
   order by ts.opened_at desc
   limit 1;

  if v_other_session is null then
    update public.table_sessions set closed_at = null where id = v_session;
    update public.dining_tables
       set state = 'occupied'
     where id = v_table
       and state is distinct from 'occupied';
    insert into public.orphan_order_revivals (
      order_id, session_id, table_id, business_id,
      closed_at_before, status_ext_before, source
    ) values (
      p_order_id, v_session, v_table, v_business,
      v_session_closed, v_status::text, 'order_item_insert_session'
    );
    return 'reattached';
  end if;

  update public.orders
     set session_id    = v_other_session,
         review_reason = coalesce(review_reason, 'late_items_after_release'),
         review_at     = coalesce(review_at, now())
   where id = p_order_id;
  insert into public.orphan_order_revivals (
    order_id, session_id, table_id, business_id,
    closed_at_before, status_ext_before, source
  ) values (
    p_order_id, v_session, v_table, v_business,
    v_session_closed, v_status::text, 'order_item_insert_session_review'
  );
  insert into public.order_review_events (
    order_id, business_id, event, session_id, table_id
  ) values (p_order_id, v_business, 'late_items_moved', v_other_session, v_table);
  return 'moved_to_review';
end;
$function$;

revoke all on function public.fn_reattach_orphan_order(uuid) from public, anon, authenticated;
grant execute on function public.fn_reattach_orphan_order(uuid) to service_role;

CREATE OR REPLACE FUNCTION public.fn_release_empty_table(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_session_id     uuid;
  v_table_id       uuid;
  v_business_id    uuid;
  v_live_items     integer;
  v_other_orders   integer;
  v_closed_session boolean := false;
BEGIN
  IF p_order_id IS NULL THEN
    RETURN jsonb_build_object('released', false, 'reason', 'null_order');
  END IF;

  SELECT o.session_id,
         ts.table_id,
         coalesce(ts.business_id, z.business_id)
    INTO v_session_id, v_table_id, v_business_id
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
    LEFT JOIN public.zones z ON z.id = dt.zone_id
   WHERE o.id = p_order_id;

  IF v_session_id IS NULL THEN
    RETURN jsonb_build_object('released', false, 'reason', 'order_not_found');
  END IF;

  -- Access check. El alias de columna va EXPLÍCITO: current_user_business_ids()
  -- devuelve SETOF uuid, así que un `c.business_id` sin `AS c(business_id)`
  -- lanza 42703 para el caller `authenticated` y NUNCA falla con service_role
  -- (ver project_current_user_business_ids_alias_42703).
  IF v_business_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
         FROM public.current_user_business_ids() AS c(business_id)
        WHERE c.business_id = v_business_id
     ) THEN
    RAISE EXCEPTION 'No autorizado para liberar mesas de este negocio';
  END IF;

  -- ─── EL LOCK ───────────────────────────────────────────────────────────
  -- Serializa contra fn_open_table (que retiene esta fila desde su
  -- `UPDATE dining_tables SET state='occupied'` hasta el COMMIT).
  -- 20261010_0023: además el candado por mesa de fn_open_table. El FOR UPDATE
  -- solo no lo excluye (fn_open_table no toca esa fila si la mesa ya está
  -- ocupada): una apertura podía crear su orden en la sesión que esta salida
  -- cerraba → orden viva sin mesa. Ahora una espera a la otra.
  IF v_table_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(v_table_id::text, 0));
    PERFORM 1 FROM public.dining_tables WHERE id = v_table_id FOR UPDATE;
  END IF;

  -- ─── RE-CHEQUEO DESPUÉS DEL LOCK ───────────────────────────────────────
  -- Aquí está toda la diferencia con la versión de la app: estas lecturas ven
  -- lo que se committeó mientras esperábamos el lock.
  SELECT count(*)
    INTO v_live_items
    FROM public.order_items oi
   WHERE oi.order_id = p_order_id
     AND oi.status IS DISTINCT FROM 'void';

  IF v_live_items > 0 THEN
    RETURN jsonb_build_object('released', false, 'reason', 'order_has_items');
  END IF;

  -- Solo se anula la orden si sigue abierta. `status` se deja como estaba a
  -- propósito: la versión anterior tampoco lo tocaba y hay consultas por todo
  -- el repo que filtran por él.
  UPDATE public.orders
     SET status_ext = 'void',
         closed_at  = now()
   WHERE id = p_order_id
     AND closed_at IS NULL;

  SELECT count(*)
    INTO v_other_orders
    FROM public.orders o
   WHERE o.session_id = v_session_id
     AND o.id <> p_order_id
     AND o.closed_at IS NULL
     AND o.status_ext NOT IN ('paid', 'void');

  IF v_other_orders = 0 THEN
    UPDATE public.table_sessions
       SET closed_at = now()
     WHERE id = v_session_id
       AND closed_at IS NULL;

    v_closed_session := true;

    IF v_table_id IS NOT NULL THEN
      UPDATE public.dining_tables
         SET state = 'available'
       WHERE id = v_table_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'released',       true,
    'closed_session', v_closed_session,
    'session_id',     v_session_id,
    'table_id',       v_table_id,
    'other_orders',   v_other_orders
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_release_empty_table(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_release_empty_table(uuid) TO authenticated;

create or replace function public.fn_block_items_on_closed_order()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_state          text;
  v_target         uuid;
  v_check          uuid;
  v_order_closed   timestamptz;
  v_session_closed timestamptz;
  v_found          boolean;
begin
  if new.order_id is null then
    return new;
  end if;

  -- Camino normal: una lectura por PK (orden y su sesión).
  select o.closed_at, ts.closed_at, true
    into v_order_closed, v_session_closed, v_found
    from public.orders o
    left join public.table_sessions ts on ts.id = o.session_id
   where o.id = new.order_id;

  if not coalesce(v_found, false)
     or (v_order_closed is null and v_session_closed is null) then
    return new;
  end if;

  -- Orden VIVA en una sesión CERRADA (huérfana, 20261010_0023): vuelve a su
  -- mesa (o queda en revisión si la mesa ya es de otra cuenta) y el producto
  -- entra. Antes entraba a una orden que el salón no muestra.
  if v_order_closed is null then
    perform public.fn_reattach_orphan_order(new.order_id);
    return new;
  end if;

  v_state := public.fn_reopen_orphan_order(new.order_id, 'order_item_insert');

  if v_state in ('revived', 'not_closed') then
    return new;
  elsif v_state = 'table_taken' then
    perform public.fn_move_closed_order_to_review(new.order_id);
    return new;
  elsif v_state = 'settled' then
    v_target := public.fn_late_items_review_order(new.order_id);
    if v_target is null then
      raise exception 'Esta cuenta ya fue cobrada. Abre la mesa otra vez para cargar productos nuevos.'
        using errcode = 'MP401';
    end if;
    select oc.id into v_check
      from public.order_checks oc
     where oc.order_id = v_target
       and not coalesce(oc.is_closed, false)
     order by oc.position
     limit 1;
    new.order_id := v_target;
    new.check_id := v_check;
    return new;
  else
    raise exception 'La orden ya no existe.'
      using errcode = 'MP403';
  end if;
end;
$function$;

alter function public.fn_block_items_on_closed_order() owner to postgres;

commit;
