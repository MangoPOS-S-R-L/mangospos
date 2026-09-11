-- =============================================================================
-- DIAGNOSTICO: la nota de venta esta consumiendo NCF
--
-- Correr COMPLETO en el SQL Editor de Supabase y pasar los 6 resultados.
-- Cada bloque descarta una causa distinta. Es todo SELECT: no cambia nada.
-- =============================================================================

-- 1) Migracion aplicada? Deben salir las 3 columnas de flags, las 2 marcas,
--    la tabla, la vista y la funcion. Si falta algo, la 20260910_0001 no corrio
--    (o corrio a medias).
select
  to_regclass('public.sales_notes')                             as tabla_sales_notes,
  to_regclass('public.sales_documents')                         as vista_sales_documents,
  to_regprocedure('public.fn_issue_sales_note(uuid,uuid)')      as fn_emision,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='business_settings'
      and column_name in ('sales_note_enabled','sales_note_prefix','sales_note_default')
  )                                                             as cols_business_settings_de_3,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='orders' and column_name='is_sales_note'
  )                                                             as col_orders_de_1,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='order_checks' and column_name='is_sales_note'
  )                                                             as col_order_checks_de_1;

-- 2) QUIEN emite el comprobante en esta base. Esta es la causa mas probable:
--    si sigue vivo un trigger sobre `payments`, el NCF se quema al INSERTAR el
--    pago y el desvio (que vive en el cierre de orden/sub-cuenta) nunca corre.
select
  c.relname   as tabla,
  t.tgname    as trigger,
  p.proname   as funcion,
  t.tgenabled as habilitado   -- 'O' = activo, 'D' = deshabilitado
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_proc  p on p.oid = t.tgfoid
where not t.tgisinternal
  and c.relname in ('payments','orders','order_checks')
order by c.relname, t.tgname;

-- 3) El guard esta REALMENTE en el cuerpo vivo de las funciones de cierre?
--    Las dos tienen que decir true. Si alguna dice false, el CREATE OR REPLACE
--    de la migracion no llego a esa funcion (o algo la piso despues).
select
  'trg_fn_issue_fd_on_order_close' as funcion,
  pg_get_functiondef('public.trg_fn_issue_fd_on_order_close()'::regprocedure)
    like '%fn_issue_sales_note%' as tiene_guard
union all
select
  'trg_fn_issue_fd_on_check_close',
  pg_get_functiondef('public.trg_fn_issue_fd_on_check_close()'::regprocedure)
    like '%fn_issue_sales_note%';

-- 4) La funcion vieja `trigger_issue_fiscal_on_payment`: es no-op o emite?
--    Si contiene 'issue_fiscal_document' Y el punto 2 la muestra con trigger
--    activo sobre payments, esa es la fuga.
select
  pg_get_functiondef('public.trigger_issue_fiscal_on_payment()'::regprocedure)
    like '%issue_fiscal_document%' as emite_por_payment;

-- 5) Las ultimas 10 ventas: que se marco y que se emitio.
--    Lo que buscamos: filas con `marcada_como_nota` = true que igual tengan NCF.
select
  o.id                                   as order_id,
  o.closed_at,
  o.is_sales_note                        as orden_marcada,
  (select bool_or(c.is_sales_note) from public.order_checks c
    where c.order_id = o.id)             as algun_check_marcado,
  (select sn.note_number from public.sales_notes sn
    where sn.order_id = o.id and sn.status='active' limit 1) as nota_emitida,
  (select fd.ncf_number from public.fiscal_documents fd
    where fd.order_id = o.id and fd.status='active'
    order by fd.created_at desc limit 1)  as ncf_quemado,
  (select fd.check_id is not null from public.fiscal_documents fd
    where fd.order_id = o.id and fd.status='active'
    order by fd.created_at desc limit 1)  as ncf_era_de_subcuenta
from public.orders o
where o.closed_at is not null
order by o.closed_at desc
limit 10;

-- 6) Cuanto rango se gasto hoy, por tipo. Para dimensionar el dano.
select
  s.ncf_type,
  s.prefix,
  s.current_number,
  s.range_end,
  s.range_end - s.current_number as disponibles,
  (select count(*) from public.fiscal_documents fd
    where fd.ncf_sequence_id = s.id
      and fd.created_at >= current_date) as emitidos_hoy
from public.ncf_sequences s
where s.is_active = true
order by s.ncf_type;
