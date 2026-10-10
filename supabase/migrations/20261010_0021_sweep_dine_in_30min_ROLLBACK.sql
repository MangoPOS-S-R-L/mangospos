-- Reversa de 20261010_0021: vuelve el mínimo de 6 h de las mesas de salón
-- (cuerpo de 20261010_0004, md5(prosrc) f681b45052c86bb3ad2b586cf8ef93a2).
begin;

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
  -- Contención (20261010_0004): mesas de salón, mínimo 6 h.
  v_cutoff_dine_in timestamptz := now() - make_interval(mins => greatest(360, coalesce(p_older_than_minutes, 20)));
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

commit;
