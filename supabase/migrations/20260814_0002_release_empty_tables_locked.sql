-- =============================================================================
-- 20260814_0002 — El barrendero de mesas vacías también toma el lock por mesa
-- =============================================================================
--
-- EL AGUJERO (segunda puerta de las órdenes huérfanas, ver 20260814_0001):
--   `fn_release_empty_tables` cerraba sesiones con CTEs evaluadas contra el
--   snapshot del inicio de la sentencia:
--
--     sessions_to_close as (
--       select ts.id, ts.table_id from public.table_sessions ts
--        where ts.closed_at is null
--          and coalesce(ts.opened_at,'epoch'::timestamptz) < v_cutoff
--          and not exists (select 1 from public.orders o
--                           where o.session_id = ts.id and o.closed_at is null
--                             and o.status_ext not in ('paid','void'))
--     )
--
--   Si `fn_open_table` committea DESPUÉS de ese snapshot, el `not exists` no ve
--   la orden nueva y el UPDATE cierra la sesión igual. La orden queda viva
--   colgando de una sesión cerrada: invisible en el salón, nunca cobrada, y con
--   los insumos ya descontados si alcanzó a imprimir comanda.
--
--   Y esto NO es una carrera de milisegundos como la de la app. El escenario es
--   cotidiano:
--
--     Un mesero abre una mesa y se va sin pedir nada. Vuelve 20 minutos
--     después a tomar la orden. En ese instante otro dispositivo carga el
--     salón — la app llama a esta función en CADA carga del salón, no solo
--     el cron (sales_by_zone_viewmodel.dart) — y le cierra la mesa encima.
--
--   Ojo con el diagnóstico: este camino escribe con `now()` del servidor, así
--   que sus sesiones salen con `closed_at >= opened_at` y NO tienen el desfase
--   de 4 h que delata a la app. En los scripts de diagnóstico aparecían
--   etiquetadas como "servidor = cierre legítimo".
--
-- EL ARREGLO: mismo lock que fn_open_table, por mesa, con re-chequeo dentro.
--   La lógica de negocio NO cambia — ni un filtro, ni el guard de cobertura de
--   pago que impide cerrar órdenes `paid` sin `payments` que las respalden (esa
--   protección es la que evita que el barrido tape ventas sin cobrar).
--   Lo único que cambia es CÓMO se recorre:
--
--     · Antes: dos sentencias masivas sobre todo el universo de candidatos.
--     · Ahora: se arma la lista de mesas candidatas, y por cada una se toma
--       `pg_advisory_xact_lock(hashtextextended(table_id::text, 0))` — la MISMA
--       expresión que fn_open_table — y se re-evalúa todo DENTRO del lock.
--       En READ COMMITTED cada sentencia toma snapshot nuevo, así que el
--       re-chequeo posterior al lock sí ve la orden recién committeada.
--
--   Se usa `pg_TRY_advisory_xact_lock`: si la mesa está tomada en este preciso
--   momento (alguien la está abriendo), se SALTA y la agarra el próximo
--   barrido. Un barrendero nunca debe hacer esperar a un mesero.
--
--   El recorrido va `order by table_id` para que dos barridos concurrentes
--   pidan los locks en el mismo orden. Deadlock con fn_open_table no es
--   posible: esa toma UNA sola mesa y nunca pide otra.
--
-- POR QUÉ LA LISTA DE CANDIDATAS LLEVA LAS DOS RAMAS
--   La rama de ÓRDENES no es redundante: una sesión cuya única orden la anula
--   el paso 1 queda vacía DENTRO de esta misma corrida, y tiene que cerrarse
--   en esta corrida (comportamiento original). Esa sesión no entra por la rama
--   de sesiones — todavía tenía una orden abierta al armar la lista — pero su
--   mesa sí entra por la rama de órdenes. Sin las dos ramas, esas mesas se
--   quedarían un ciclo colgadas.
--
-- IDEMPOTENTE: CREATE OR REPLACE. No toca datos.
-- Cuerpo base: el VIVO de prod (verificado con pg_get_functiondef 2026-08-14),
-- que coincidía con 20260608_0003.
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
         and coalesce(o.created_at, 'epoch'::timestamptz) < v_cutoff
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
         and coalesce(ts.opened_at, 'epoch'::timestamptz) < v_cutoff
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
        and coalesce(o.created_at, 'epoch'::timestamptz) < v_cutoff
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
  end loop;

  return v_closed;
end;
$function$;

COMMENT ON FUNCTION public.fn_release_empty_tables(integer, uuid) IS
  'Barrido de mesas vacías viejas. Recorre mesa por mesa tomando el MISMO '
  'pg_advisory_xact_lock(hashtextextended(table_id::text,0)) que fn_open_table '
  '(try-lock: si la mesa está en uso ahora mismo, la salta) y re-evalúa dentro '
  'del lock. Antes usaba CTEs masivas sobre el snapshot de la sentencia y podía '
  'cerrar una sesión cuya orden fn_open_table acababa de committear → orden '
  'huérfana. Conserva intacto el guard de cobertura: una orden `paid` sin '
  'payments que la respalden NO se cierra. Si cambias la expresión del lock, '
  'cámbiala también en fn_open_table y fn_release_empty_table.';

commit;

-- =============================================================================
-- VERIFICACIÓN
-- =============================================================================
-- 1) Las TRES funciones comparten la llave del lock. Esperado: 3 filas en true.
-- SELECT p.proname,
--        pg_get_functiondef(p.oid) LIKE '%hashtextextended(%::text, 0)%' AS tiene_lock
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public'
--    AND p.proname IN ('fn_open_table', 'fn_release_empty_table', 'fn_release_empty_tables');
--
-- 2) El guard de cobertura sigue en pie. Esperado: 1 fila (true).
-- SELECT pg_get_functiondef(p.oid) LIKE '%paid_amount >= closed_checks_total - 1%' AS guard_intacto
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'fn_release_empty_tables';
--
-- 3) Sigue barriendo. Correrla acotada a un negocio con mesas vacías viejas y
--    comprobar que las libera igual que antes:
-- SELECT public.fn_release_empty_tables(20, '<business_id>');
--
-- 4) No aparecen huérfanas nuevas (scripts/diag_ordenes_huerfanas_global.sql,
--    bloque 3). Esperado: 0 filas con fecha posterior al despliegue.
-- =============================================================================
