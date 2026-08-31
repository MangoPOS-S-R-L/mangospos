-- VERIFICAR_API_LECTURA_PENDA.sql
-- Comprobacion unica del estado de la API de lectura. No cambia nada.
-- Cada fila dice OK o FALTA, con que hacer si falta.
--
-- OJO: el SQL Editor de Studio solo muestra el ULTIMO result set. Por eso todo esta armado
-- para devolver UNA sola tabla al final. Pega el archivo completo y ejecuta.

-- Se hace pasar por la API key: fija el sub del JWT al usuario analitico.
-- Las vistas son definer, asi que la RLS se evalua igual que en la API real.
select set_config('request.jwt.claim.sub',
                  (select u.id::text from auth.users u
                    where u.email = 'lectura.penda@mangopos.do'),
                  false) as sub_simulado;

with c as (
  select
    (select count(*) from pg_indexes
      where indexname in ('idx_customer_credits_fiscal_document','idx_customer_credits_order')) as idx,
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'analytics' and p.proname = 'allowed_business_id')                      as fn_escalar,
    (select count(*) from pg_views
      where schemaname = 'analytics' and definition like '%allowed_business_id()%')             as vistas_ok,
    (select count(*) from pg_views
      where schemaname = 'analytics' and definition like '%allowed_business_ids()%')            as vistas_viejas,
    (select count(*) from pg_views where schemaname = 'analytics')                              as vistas_total,
    -- Invariante real: NINGUNA vista puede quedar sin pin Y sin RLS en su tabla base.
    -- Las vistas sobre tablas sin columna business_id llevan `where true` a proposito y su
    -- alcance lo da la RLS; `documentos` hereda el pin de `documentos_detalle`. Por eso
    -- contar "vistas que mencionan la funcion" NO sirve como comprobacion.
    (select count(*)
       from pg_views v
       left join pg_class t on t.relname = v.viewname
            and t.relnamespace = 'public'::regnamespace and t.relkind = 'r'
      where v.schemaname = 'analytics'
        and v.definition not like '%allowed_business_id%'
        and v.viewname <> 'documentos'
        and coalesce(t.relrowsecurity, false) = false)                                          as vistas_sin_proteger,
    (select count(*) from auth.users where email = 'lectura.penda@mangopos.do')                 as usuario,
    (select count(*) from auth.users
      where email = 'lectura.penda@mangopos.do' and banned_until is not null)                   as baneado,
    (select count(*) from public.user_businesses ub join auth.users u on u.id = ub.user_id
      where u.email = 'lectura.penda@mangopos.do'
        and ub.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6')                            as enlace,
    (select count(*) from analytics.api_clients a join auth.users u on u.id = a.user_id
      where u.email = 'lectura.penda@mangopos.do'
        and a.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and a.is_active)             as pin,
    (select coalesce(array_to_string(rolconfig, ' '), '') from pg_roles
      where rolname = 'authenticator')                                                          as pgrst_cfg,
    (select count(*) from analytics.documentos)                                                 as feed_filas,
    (select count(*) from analytics.documentos_detalle
      where business_id <> '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6')                              as ajenas,
    (select coalesce(string_agg(t || ' ' || n, '  |  ' order by t), '(vacio)')
       from (select "TIPO_DOC" as t, count(*) as n
               from analytics.documentos group by 1) x)                                         as por_tipo
)
select n, paso, valor, estado from (
  select 1 as n, 'Indices de customer_credits' as paso, idx||' de 2' as valor,
         case when idx = 2 then 'OK' else 'FALTA: aplicar 20260830_0001' end as estado from c
  union all select 2, 'Funcion pin escalar', fn_escalar::text,
         case when fn_escalar = 1 then 'OK' else 'FALTA: aplicar 20260830_0001' end from c
  union all select 3, 'Vistas publicadas', vistas_ok||' con pin, '||(vistas_total-vistas_ok)||' por RLS, '||vistas_total||' en total',
         'informativo' from c
  union all select 31, 'Vistas SIN pin y SIN RLS', vistas_sin_proteger::text,
         case when vistas_sin_proteger = 0 then 'OK' else 'FUGA: revisar esas vistas' end from c
  union all select 4, 'Vistas con el pin viejo (lento)', vistas_viejas::text,
         case when vistas_viejas = 0 then 'OK' else 'FALTA: aplicar 20260830_0001' end from c
  union all select 5, 'Usuario analitico creado', usuario::text,
         case when usuario = 1 then 'OK' else 'FALTA: Studio > Authentication > Add user' end from c
  union all select 6, 'Enlace usuario-negocio', enlace::text,
         case when enlace = 1 then 'OK' else 'FALTA: bloque 2 de ACTIVAR' end from c
  union all select 7, 'Pin de negocio (api_clients)', pin::text,
         case when pin = 1 then 'OK' else 'FALTA: bloque 3 de ACTIVAR' end from c
  union all select 8, 'Login interactivo bloqueado', baneado::text,
         case when baneado = 1 then 'OK' else 'FALTA: bloque 4 de ACTIVAR' end from c
  union all select 9, 'Esquema analytics expuesto', case when pgrst_cfg like '%analytics%' then 'si' else 'no' end,
         case when pgrst_cfg like '%analytics%' then 'OK' else 'FALTA: bloque 6 de ACTIVAR' end from c
  union all select 10, 'Filas de OTROS negocios', ajenas::text,
         case when ajenas = 0 then 'OK' else 'FUGA: detener y revisar' end from c
  union all select 11, 'Filas que vera la API key', feed_filas::text,
         case when feed_filas > 0 then 'OK' else 'REVISAR: 0 filas, faltan los bloques 2/3' end from c
  union all select 12, 'Desglose por tipo de documento', por_tipo, 'informativo' from c
) t order by n;
