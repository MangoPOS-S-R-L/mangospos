-- 20260602_0001_release_empty_tables_cleanup.sql
-- ═══════════════════════════════════════════════════════════════════════════════
-- Problema:
--   Al abrir una mesa (fn_open_table) o una venta rápida/manual
--   (fn_open_manual_or_quick) se crean de inmediato una `table_sessions` + una
--   `orders` con totales en cero, ANTES de agregar el primer producto. Si el
--   usuario sale sin agregar nada, la limpieza del cliente
--   (releaseEmptyTableIfNeeded) corre en segundo plano y "best-effort": si la
--   app se cierra, se recarga, sale por otra ruta o falla la red, la sesión y la
--   orden vacías quedan huérfanas, ocupan espacio y bloquean el cierre de caja
--   (OPEN_TABLES_EXIST).
--
-- Cubre además un segundo caso real: split bill donde se paga cada check por
-- separado; los checks quedan cerrados y los items 'paid', pero la orden y la
-- sesión nunca se cierran (el flujo por-check no las cierra). La mesa queda
-- ocupada/azul ("En Pre-Cuenta") aunque ya no hay nada por cobrar.
--
-- OJO seguridad: existe un bug conocido donde items quedan marcados 'paid' sin
-- un pago real detrás (ver 20260530_0009). Por eso el cierre automático NO se
-- fía solo de "no hay items pendientes": la rama 'paid' exige cobertura de pagos
-- reales. Ante la duda, no cierra (la deja para revisión humana).
--
-- Solución (server-side, no depende del cliente):
--   1. fn_release_empty_tables(p_older_than_minutes): cierra órdenes abiertas que
--      llevan más de N minutos (grace period para no tocar mesas recién abiertas)
--      y NO tienen items pendientes de cobro, SOLO en casos seguros:
--        - vacía / todo anulado -> 'void' (no hay dinero de por medio);
--        - pagada con cobertura (sum(payments completados) >= total de checks
--          cerrados) -> 'paid'.
--      Luego cierra las sesiones sin órdenes abiertas y libera la mesa. Es
--      global (todos los negocios) e idempotente.
--   2. pg_cron la agenda cada 15 min con umbral de 60 min (si la extensión está
--      disponible; mismo patrón que el heartbeat de impresoras).
-- ═══════════════════════════════════════════════════════════════════════════════

begin;

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
  -- 1) Cerrar órdenes abiertas, "viejas" y SIN items pendientes de cobro,
  --    pero SOLO en los casos demostrablemente seguros. "Pendiente" = item
  --    con status que NO es 'void' ni 'paid'. Dos categorías:
  --      a) VACÍA / TODO ANULADO: sin items pendientes y sin items 'paid'
  --         (mesa abierta y abandonada, o todo void) -> cierra como 'void'.
  --         No hay dinero de por medio, es seguro.
  --      b) PAGADA REAL: sin items pendientes, con items 'paid', Y con pagos
  --         completados que CUBREN el total de los checks cerrados -> cierra
  --         como 'paid' (ej. split bill donde cada check se pagó por separado
  --         y el último pago no cerró la orden/sesión).
  --    GUARD DE COBERTURA (importante): existe un bug conocido donde items
  --    quedan marcados 'paid' SIN un pago real detrás (ver migración
  --    20260530_0009). Para no cerrar/ocultar una venta sin cobrar, la rama
  --    'paid' exige que sum(payments completados) >= sum(total de checks
  --    cerrados). Si no hay cobertura, NO se toca la orden (queda para
  --    revisión humana). Ante la duda, no cerramos.
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
  --    Guard de opened_at < cutoff: nunca tocamos sesiones recién abiertas.
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

-- pg_cron: agendar cada 15 min con umbral de 60 min (si la extensión existe).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- Borrar job previo si existe (idempotente).
    perform cron.unschedule(jobid)
    from cron.job
    where jobname = 'release_empty_tables';

    perform cron.schedule(
      'release_empty_tables',
      '*/15 * * * *',
      $cron$select public.fn_release_empty_tables(60)$cron$
    );
  else
    raise notice 'pg_cron no disponible. Agendar manualmente: select cron.schedule(''release_empty_tables'', ''*/15 * * * *'', ''select public.fn_release_empty_tables(60)'');';
  end if;
exception when insufficient_privilege then
  raise notice 'Sin privilegio para agendar pg_cron. Agendar manualmente: select cron.schedule(''release_empty_tables'', ''*/15 * * * *'', ''select public.fn_release_empty_tables(60)'');';
end $$;

commit;
