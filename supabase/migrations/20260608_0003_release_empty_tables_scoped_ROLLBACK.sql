-- ROLLBACK de 20260608_0003_release_empty_tables_scoped.sql
-- Restaura la versión global de 1 arg (20260602_0001) y reagenda su cron.

begin;

drop function if exists public.fn_release_empty_tables(integer, uuid);

create or replace function public.fn_release_empty_tables(
  p_older_than_minutes integer default 30
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cutoff timestamptz := now() - make_interval(mins => greatest(0, coalesce(p_older_than_minutes, 30)));
  v_closed int := 0;
begin
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
        else null
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

  with sessions_to_close as (
    select ts.id, ts.table_id
    from public.table_sessions ts
    where ts.closed_at is null
      and coalesce(ts.opened_at, 'epoch'::timestamptz) < v_cutoff
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
$$;

alter function public.fn_release_empty_tables(integer) owner to postgres;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'release_empty_tables';
    perform cron.schedule(
      'release_empty_tables',
      '*/15 * * * *',
      $cron$select public.fn_release_empty_tables(60)$cron$
    );
  end if;
exception when insufficient_privilege then
  null;
end $$;

commit;
