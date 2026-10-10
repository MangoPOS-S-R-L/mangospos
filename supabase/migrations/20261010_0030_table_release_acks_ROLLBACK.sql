-- Reversa de 20261010_0030 (T02): vuelve a las liberaciones vivas del 2026-10-10
-- (fn_release_empty_tables de 20261010_0021_sweep_dine_in_30min, con el
-- mínimo de 30 min para salón, y fn_release_empty_table de
-- 20261010_0023_release_lock_and_orphan_heal: fila de la mesa + candado
-- consultivo; sin confirmaciones) y borra el protocolo de T02. La app nueva deja de liberar
-- al salir de una mesa vacía (fn_release_empty_table_v2 no existe: PGRST202) y
-- no recurre a la versión anterior.
begin;

drop trigger if exists trg_zz_session_version_orders on public.orders;
drop trigger if exists trg_zz_session_version_items on public.order_items;
drop trigger if exists trg_zz_session_version_payments on public.payments;

drop function if exists public.fn_release_empty_table_v2(uuid, text, boolean);
drop function if exists public.fn_ack_session_release(uuid, text, bigint, boolean);
drop function if exists public.fn_pending_release_requests(uuid, text);
drop function if exists public.fn_register_session_participant(uuid, text);
drop function if exists public.fn_fulfill_session_release_locked(uuid);
drop function if exists public.fn_release_left_order_locked(uuid);
drop function if exists public.fn_release_session_sweep_locked(uuid, timestamptz);
drop function if exists public.fn_request_session_release(uuid, text, uuid);
drop function if exists public.fn_session_release_blocker(uuid, bigint);
drop function if exists public.fn_device_retired(uuid, text);
drop function if exists public.fn_assert_session_member(uuid);
drop function if exists public.fn_session_business(uuid);
drop function if exists public.trg_session_version_from_order_ref();
drop function if exists public.trg_session_version_from_order();
drop function if exists public.fn_session_version(uuid);
drop function if exists public.fn_bump_session_version(uuid);

drop table if exists public.table_session_release_acks;
drop table if exists public.table_session_release_requests;
drop table if exists public.table_session_participants;
drop table if exists public.table_session_versions;

CREATE OR REPLACE FUNCTION public.fn_release_empty_tables(
  p_older_than_minutes integer DEFAULT 20,
  p_business_id uuid DEFAULT NULL::uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_cutoff timestamptz := now() - make_interval(mins => greatest(0, coalesce(p_older_than_minutes, 20)));
  -- Mesas de salón: mínimo 30 min (20261010_0021; 20261010_0004 tenía 6 h).
  v_cutoff_dine_in timestamptz := now() - make_interval(mins => greatest(30, coalesce(p_older_than_minutes, 20)));
  v_closed int := 0;
  v_batch  int := 0;
  v_table  uuid;
begin
  -- Guard de tenant: si se pide acotado a un negocio, el caller debe pertenecer
  -- a él. El barrido global (p_business_id null) lo dispara solo pg_cron.
  if p_business_id is not null and not public.is_member_of_business(p_business_id) then
    raise exception 'forbidden';
  end if;

  for v_table in
    select tbl
    from (
      -- Rama A: mesas con órdenes candidatas a cerrarse (paso 1).
      select ts.table_id as tbl
        from public.orders o
        join public.table_sessions ts on ts.id = o.session_id
       where o.closed_at is null
         and o.status_ext not in ('paid', 'void')
         and coalesce(o.created_at, 'epoch'::timestamptz)
             < case when ts.origin::text = 'dine_in' then v_cutoff_dine_in else v_cutoff end
         and not exists (
           select 1 from public.order_items oi
            where oi.order_id = o.id
              and oi.status not in ('void', 'paid')
         )
         and (p_business_id is null or ts.business_id = p_business_id)

      union

      -- Rama B: mesas con sesiones ya vacías candidatas a cerrarse (paso 2).
      select ts.table_id
        from public.table_sessions ts
       where ts.closed_at is null
         and coalesce(ts.opened_at, 'epoch'::timestamptz)
             < case when ts.origin::text = 'dine_in' then v_cutoff_dine_in else v_cutoff end
         and (p_business_id is null or ts.business_id = p_business_id)
         and not exists (
           select 1 from public.orders o
            where o.session_id = ts.id
              and o.closed_at is null
              and o.status_ext not in ('paid', 'void')
         )
    ) c
    where tbl is not null
    order by tbl
  loop
    -- Mesa ocupada por una apertura en vuelo: se salta, la agarra el próximo
    -- barrido. Nunca se hace esperar a un mesero por una tarea de limpieza.
    if not pg_try_advisory_xact_lock(hashtextextended(v_table::text, 0)) then
      continue;
    end if;

    -- ─── PASO 1 (dentro del lock) ─────────────────────────────────────────
    -- Cerrar órdenes abiertas, "viejas" y SIN items pendientes de cobro, solo
    -- en casos demostrablemente seguros (ver migración 20260602_0001).
    with candidates as (
      select o.id,
             exists (
               select 1 from public.order_items oi
               where oi.order_id = o.id and oi.status = 'paid'
             ) as has_paid
      from public.orders o
      join public.table_sessions ts on ts.id = o.session_id
      where ts.table_id = v_table
        and o.closed_at is null
        and o.status_ext not in ('paid', 'void')
        and coalesce(o.created_at, 'epoch'::timestamptz)
            < case when ts.origin::text = 'dine_in' then v_cutoff_dine_in else v_cutoff end
        and not exists (
          select 1 from public.order_items oi
          where oi.order_id = o.id
            and oi.status not in ('void', 'paid')
        )
        and (p_business_id is null or ts.business_id = p_business_id)
    ),
    classified as (
      select c.id, c.has_paid,
        coalesce((
          select sum(p.amount) from public.payments p
          where p.order_id = c.id and p.status = 'completed'
        ), 0) as paid_amount,
        coalesce((
          select sum(oc.total) from public.order_checks oc
          where oc.order_id = c.id and oc.is_closed
        ), 0) as closed_checks_total
      from candidates c
    ),
    to_close as (
      select id,
        case
          when not has_paid then 'void'::public.order_status
          when paid_amount > 0
               and closed_checks_total > 0
               and paid_amount >= closed_checks_total - 1
            then 'paid'::public.order_status
          else null  -- 'paid' sin cobertura: NO tocar, dejar para revisión.
        end as final_status
      from classified
    ),
    updated as (
      update public.orders o
      set status_ext = t.final_status,
          closed_at = now()
      from to_close t
      where o.id = t.id
        and t.final_status is not null
      returning o.id
    )
    select count(*) into v_batch from updated;

    v_closed := v_closed + coalesce(v_batch, 0);

    -- ─── PASO 2 (dentro del lock) ─────────────────────────────────────────
    -- Cerrar sesiones que ya no tienen ninguna orden abierta y liberar la mesa.
    -- Esta sentencia toma snapshot nuevo: ve lo que el paso 1 acaba de anular
    -- Y ve cualquier orden que fn_open_table haya committeado mientras
    -- esperábamos — que es justo lo que antes se perdía.
    with sessions_to_close as (
      select ts.id, ts.table_id
      from public.table_sessions ts
      where ts.table_id = v_table
        and ts.closed_at is null
        and coalesce(ts.opened_at, 'epoch'::timestamptz)
            < case when ts.origin::text = 'dine_in' then v_cutoff_dine_in else v_cutoff end
        and (p_business_id is null or ts.business_id = p_business_id)
        and not exists (
          select 1 from public.orders o
          where o.session_id = ts.id
            and o.closed_at is null
            and o.status_ext not in ('paid', 'void')
        )
    ),
    closed as (
      update public.table_sessions ts
      set closed_at = now()
      from sessions_to_close s
      where ts.id = s.id
      returning ts.table_id
    )
    update public.dining_tables dt
    set state = 'available'
    where dt.id in (select table_id from closed where table_id is not null)
      and dt.state <> 'available';
  end loop;

  return v_closed;
end;
$function$;

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

commit;
