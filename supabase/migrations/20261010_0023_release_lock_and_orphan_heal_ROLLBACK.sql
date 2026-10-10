-- Reversa de 20261010_0023: vuelve fn_release_empty_table viva del 10-oct
-- (solo FOR UPDATE; md5 5dc47a35…) y el candado de ítems de 20261010_0020;
-- borra fn_reattach_orphan_order. Las órdenes ya reubicadas no se tocan.
begin;

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
  IF v_table_id IS NOT NULL THEN
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
  v_state  text;
  v_target uuid;
  v_check  uuid;
begin
  if new.order_id is null then
    return new;
  end if;

  if not exists (
    select 1 from public.orders o
     where o.id = new.order_id
       and o.closed_at is not null
  ) then
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

drop function if exists public.fn_reattach_orphan_order(uuid);

commit;
