-- =============================================================================
-- El Nido (2ª vuelta): ¿qué barrido está vivo? + cuentas en revisión (SOLO LECTURA)
-- =============================================================================
-- La 1ª vuelta (review_el_nido_open_empty_tables.sql, 16-oct) mostró que el cron
-- corre sin errores pero NO anula cuentas vacías (TERRAZA - MESA 10, carril
-- quick, y las cuentas vacías dentro de las mesas con cuenta en revisión).
--
-- Una sola tabla:
--   1 FUNCIÓN   huella md5(prosrc) de las liberaciones vivas vs. las del repo
--               (definición completa solo si la huella es desconocida)
--   2 T02       restos de 20261010_0030 (tablas/triggers que la reversa borra)
--   3 REVISIÓN  productos de cada cuenta en revisión de El Nido y cuándo se cobró
--               la cuenta de origen
--   4 VACÍA     las cuentas vacías que el barrido debió anular: ¿alguien las tocó?
-- Hora en República Dominicana.
-- =============================================================================
with fn as (
  select p.oid::regprocedure::text as firma,
         left(md5(p.prosrc), 8) as huella,
         pg_get_functiondef(p.oid) as definicion
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('fn_release_empty_tables', 'fn_release_empty_table',
                       'fn_release_empty_table_v2')
),
nido as (
  select 'd2aea1c8-f927-479c-9581-b236d6df3955'::uuid as id
),
rev as (
  select o.id, o.created_at, ts.id as session_id, dt.code as mesa,
         to_jsonb(o) as j
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    join public.dining_tables dt on dt.id = ts.table_id
    join public.zones z on z.id = dt.zone_id
   where coalesce(ts.business_id, z.business_id) = (select id from nido)
     and ts.closed_at is null
     and o.closed_at is null
     and o.status_ext::text not in ('paid', 'void')
     and to_jsonb(o) ->> 'review_reason' is not null
)
select n, seccion, que, cuando, valor, detalle
  from (
    -- 1. Funciones de liberación vivas
    select 1 as n, 'FUNCIÓN' as seccion, f.firma as que, null::text as cuando,
           f.huella || ' = ' || case f.huella
             when '03248ee6' then 'barrido 0021 (30 min) — ESPERADO'
             when 'f681b450' then 'barrido 0004 (6 h)'
             when '76a7eb78' then 'barrido 0030 T02 — NO debería estar'
             when 'fc268e83' then 'salida 0023 — ESPERADA'
             when '35fe3f4a' then 'salida 0030 T02 — NO debería estar'
             else 'DESCONOCIDA (ver definición)'
           end as valor,
           case when f.huella in ('03248ee6', 'fc268e83') then null
                else jsonb_build_object('definicion', f.definicion) end as detalle
      from fn f

    union all

    -- 2. Restos de T02 (20261010_0030)
    select 2, 'T02', x.objeto, null,
           case when x.existe then 'EXISTE (la reversa de 0030 lo borra)' else 'no existe' end,
           null
      from (
        select t as objeto, to_regclass('public.' || t) is not null as existe
          from unnest(array['table_session_participants', 'table_session_versions',
                            'table_session_release_requests', 'table_session_release_acks']) t
        union all
        select 'trigger ' || g, exists (select 1 from pg_trigger tg where tg.tgname = g)
          from unnest(array['trg_zz_session_version_orders', 'trg_zz_session_version_items',
                            'trg_zz_session_version_payments']) g
      ) x

    union all

    -- 3. Cuentas en revisión de El Nido: productos y cuenta de origen
    select 3, 'REVISIÓN', r.mesa || ' · cuenta ' || left(r.id::text, 8),
           to_char(r.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
           (r.j ->> 'review_reason') || ' · RD$' ||
             coalesce((select sum(oi.total) from public.order_items oi
                        where oi.order_id = r.id
                          and oi.status::text not in ('void', 'paid')), 0),
           jsonb_build_object(
             'productos', (
               select jsonb_agg(jsonb_build_object(
                        'producto', oi.product_name,
                        'cant', coalesce(oi.qty, oi.quantity),
                        'precio', oi.unit_price,
                        'total', oi.total,
                        'estado', oi.status::text,
                        'agregado', to_char(oi.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI:SS'),
                        'autor', coalesce(to_jsonb(oi) ->> 'created_by_employee_id',
                                          to_jsonb(oi) ->> 'employee_id',
                                          to_jsonb(oi) ->> 'created_by'))
                      order by oi.created_at)
                 from public.order_items oi
                where oi.order_id = r.id),
             'cuenta_origen', (
               select jsonb_build_object(
                        'cuenta', left(src.id::text, 8),
                        'estado', src.status_ext::text,
                        'creada', to_char(src.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
                        'cerrada', to_char(src.closed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI:SS'),
                        'cobros', (select jsonb_agg(jsonb_build_object(
                                     'monto', p.amount, 'estado', p.status,
                                     'hora', to_char(p.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI:SS'))
                                     order by p.created_at)
                                     from public.payments p where p.order_id = src.id))
                 from public.orders src
                where src.id = nullif(r.j ->> 'review_source_order_id', '')::uuid),
             'eventos', (
               select jsonb_agg(to_jsonb(e) - 'business_id' - 'order_id')
                 from public.order_review_events e
                where e.order_id = r.id)
           )
      from rev r

    union all

    -- 4. Cuentas vacías vivas de El Nido con más de 30 min: ¿alguien las tocó?
    select 4, 'VACÍA', dt.code || ' · cuenta ' || left(o.id::text, 8),
           to_char(o.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
           'actualizada ' || coalesce(to_char((to_jsonb(o) ->> 'updated_at')::timestamptz
                                               at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI:SS'), '¿?'),
           jsonb_build_object('origen', ts.origin::text,
                              'version', to_jsonb(o) -> 'version',
                              'status', o.status,
                              'client_order_id', to_jsonb(o) ->> 'client_order_id')
      from public.orders o
      join public.table_sessions ts on ts.id = o.session_id
      join public.dining_tables dt on dt.id = ts.table_id
      join public.zones z on z.id = dt.zone_id
     where coalesce(ts.business_id, z.business_id) = (select id from nido)
       and ts.closed_at is null
       and o.closed_at is null
       and o.status_ext::text not in ('paid', 'void')
       and o.created_at < now() - interval '30 minutes'
       and not exists (select 1 from public.order_items oi where oi.order_id = o.id)
  ) q
 order by n, que;
