-- =============================================================================
-- ROLLBACK 20260814_0002 — restaurar fn_release_empty_tables SIN el lock
-- =============================================================================
-- Cuerpo exacto que estaba vivo en prod antes de la migración (capturado con
-- pg_get_functiondef el 2026-08-14; coincidía con 20260608_0003).
--
-- ⚠ Volver aquí reabre la segunda puerta de las órdenes huérfanas: el barrido
-- puede cerrar una sesión cuya orden `fn_open_table` acaba de committear. No
-- rompe nada de inmediato — simplemente vuelve a perder órdenes de vez en
-- cuando, en silencio, y sin el desfase de 4 h que las delataba.
-- =============================================================================

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
  v_closed int := 0;
begin
  -- Guard de tenant: si se pide acotado a un negocio, el caller debe pertenecer
  -- a él. El barrido global (p_business_id null) lo dispara solo pg_cron.
  if p_business_id is not null and not public.is_member_of_business(p_business_id) then
    raise exception 'forbidden';
  end if;

  -- 1) Cerrar órdenes abiertas, "viejas" y SIN items pendientes de cobro, solo
  --    en casos demostrablemente seguros (ver migración 20260602_0001).
  with candidates as (
    select o.id,
           exists (
             select 1 from public.order_items oi
             where oi.order_id = o.id and oi.status = 'paid'
           ) as has_paid
    from public.orders o
    where o.closed_at is null
      and o.status_ext not in ('paid', 'void')
      and coalesce(o.created_at, 'epoch'::timestamptz) < v_cutoff
      and not exists (
        select 1 from public.order_items oi
        where oi.order_id = o.id
          and oi.status not in ('void', 'paid')
      )
      -- Filtro opcional por negocio (orders no tiene business_id directo).
      and (
        p_business_id is null
        or exists (
          select 1 from public.table_sessions ts
          where ts.id = o.session_id and ts.business_id = p_business_id
        )
      )
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
  select count(*) into v_closed from updated;

  -- 2) Cerrar sesiones que ya no tienen ninguna orden abierta y liberar la mesa.
  with sessions_to_close as (
    select ts.id, ts.table_id
    from public.table_sessions ts
    where ts.closed_at is null
      and coalesce(ts.opened_at, 'epoch'::timestamptz) < v_cutoff
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

  return v_closed;
end;
$function$;

commit;
