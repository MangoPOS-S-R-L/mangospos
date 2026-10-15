-- =============================================================================
-- UNIF_0_diagnostico.sql — Estancia Nueva · CAFETERÍA (85924083)
--
-- Unificar el inventario en UNA sola bodega (la principal, que pasa a llamarse
-- «__NOMBRE_PRINCIPAL__») con el conteo del 01-oct (cafetería + almacén) MENOS
-- lo que se movió después del corte __CORTE__ (la cafetería se contó en la
-- mañana, antes de abrir: se descuentan todas las ventas).
--
-- SOLO LEE. Es UNA sola consulta: el SQL Editor muestra solo el último
-- resultado. Correr ANTES de UNIF_1_aplicar.sql y pasar el resultado.
--
-- GENERADO por build_unificar_almacen.py desde
-- inventario_estancia_nueva_2026-10-01.json (__N_CONTEO__ códigos de cafetería).
-- Editar el .py o el _tpl, no este archivo.
-- =============================================================================
with
p as (
  select '__BUSINESS__'::uuid    as b,
         '__PC_CORTE__'::text    as pc_corte,
         '__PC_ABANDONADO__'::text as pc_abandonado,
         '__CORTE__'::timestamptz as corte,
         'America/Santo_Domingo'::text as tz
),
conteo (codigo, descripcion, caf, alm, total) as (
  values
__CONTEO_VALUES__
),
wh as (
  select w.id, w.name, coalesce(w.is_main, false) as is_main,
         coalesce(w.is_active, true) as is_active, w.created_at,
         to_jsonb(w) as j, w.name = '__IN_TRANSIT__' as transito
  from public.warehouses w, p
  where w.business_id = p.b
),
-- La misma regla que usa la venta para elegir la bodega por defecto.
principal as (
  select id, name from wh
  where not transito
  order by is_main desc, created_at asc nulls first, id asc
  limit 1
),
-- id = el conteo del almacén (sus ajustes los reemplaza el JSON);
-- frozen_at = la hora de corte elegida (no la del conteo del almacén).
corte as (
  select (select s.id from public.physical_count_sessions s
           where s.business_id = p.b and s.code = p.pc_corte) as id,
         p.corte as frozen_at
  from p
),
ses as (
  select s.id, s.code, s.status, s.frozen_at, s.completed_at, w.name as bodega,
         s.status = 'completed'
           and (s.frozen_at at time zone p.tz)::date = date '2026-10-01' as campania
  from public.physical_count_sessions s
  join public.warehouses w on w.id = s.warehouse_id, p
  where s.business_id = p.b
),
it as (
  select ii.id, ii.sku, ii.barcode, ii.name, coalesce(ii.cost, 0) as cost
  from public.inventory_items ii, p
  where ii.business_id = p.b
),
-- Emparejar por código: sku primero; si no hay sku, código de barras.
mt as (
  select c.*, x.n_sku, x.n_bc,
         case when x.n_sku = 1 then (select it.id from it where it.sku = c.codigo)
              when x.n_sku = 0 and x.n_bc = 1
                then (select it.id from it where it.barcode = c.codigo)
         end as item_id
  from conteo c
  cross join lateral (
    select (select count(*) from it where it.sku = c.codigo)     as n_sku,
           (select count(*) from it where it.barcode = c.codigo) as n_bc
  ) x
),
-- Lo que pasó DESPUÉS del corte y cuenta para el objetivo: todo, salvo los
-- ajustes de los conteos del 01-oct (el JSON los reemplaza), la bodega en
-- tránsito y lo que haya hecho esta misma unificación.
mov as (
  select im.item_id, im.warehouse_id, im.movement_type::text as tipo,
         im.quantity, im.reference_type,
         to_jsonb(im)->>'reason_code' as reason
  from public.inventory_movements im, p, corte k
  where im.business_id = p.b
    and im.created_at > k.frozen_at
    and im.warehouse_id not in (select id from wh where transito)
    -- coalesce: con reference_type o reference_id en NULL el `not (...)`
    -- daría NULL y el movimiento se perdería.
    and not coalesce(im.reference_type = 'physical_count'
                     and im.reference_id in (select id from ses where campania), false)
    and coalesce(im.reference_type, '') not like '%unificacion_almacen%'
),
st as (
  select s.item_id, s.warehouse_id, coalesce(s.quantity, 0) as q
  from public.inventory_stock s
  where s.warehouse_id in (select id from wh where not transito)
),
obj as (
  select mt.codigo, mt.descripcion, mt.item_id, mt.total,
         coalesce((select sum(mov.quantity) from mov
                    where mov.item_id = mt.item_id), 0) as post,
         coalesce((select sum(st.q) from st
                    where st.item_id = mt.item_id), 0) as actual
  from mt
  where mt.item_id is not null
),
filas (orden, seccion, item, detalle) as (
  -- 0 · Hora de corte: desde aquí se descuentan las ventas.
  select 0, '0 CORTE', 'ventas descontadas desde',
         to_char(p.corte at time zone p.tz, 'DD/MM/YYYY HH24:MI') || ' (hora RD)'
  from p
  union all
  select 0, '0 CORTE', p.pc_corte || ' (almacén)',
         coalesce((select s.status || ' · congelado '
                          || to_char(s.frozen_at at time zone p.tz, 'DD/MM/YYYY HH24:MI')
                     from public.physical_count_sessions s
                    where s.business_id = p.b and s.code = p.pc_corte),
                  '✗ NO EXISTE: el aplicar se niega')
  from p

  union all
  -- 1 · Ajustes del negocio que importan aquí.
  select 1, '1 AJUSTES', k.k, coalesce(bs.j->>k.k, '(columna no existe)')
  from (select to_jsonb(s) as j from public.business_settings s, p
         where s.business_id = p.b) bs
  cross join unnest(array['inventory_mode', 'warehouse_sections_enabled',
                          'transfers_require_approval',
                          'inventory_costing_method']) as k(k)

  union all
  -- 2 · Bodegas, con su existencia y lo que se movió en cada una.
  select 2, '2 BODEGAS',
         wh.name || case when wh.id = (select id from principal)
                         then '  ◀ PRINCIPAL (aquí cae la venta) → «__NOMBRE_PRINCIPAL__»'
                         when wh.transito then ''
                         when not wh.is_active then '  (ya apagada)'
                         else '  → se apaga' end,
         format('principal=%s · activa=%s · en_POS=%s · tipo=%s · área=%s · creada %s · id %s'
                || ' | existencia: %s ítems ≠0 (%s negativos), %s u, RD$%s'
                || ' | movimientos: %s; tras el corte: ventas %s u, otros %s u',
                wh.is_main, wh.is_active,
                coalesce(wh.j->>'shows_in_pos', '-'),
                coalesce(wh.j->>'warehouse_type', '-'),
                coalesce((select pa.name from public.print_areas pa
                           where pa.id::text = wh.j->>'production_area_id'), '-'),
                to_char(wh.created_at at time zone p.tz, 'DD/MM/YY HH24:MI'), wh.id,
                (select count(*) from public.inventory_stock s
                  where s.warehouse_id = wh.id and s.quantity <> 0),
                (select count(*) from public.inventory_stock s
                  where s.warehouse_id = wh.id and s.quantity < 0),
                (select round(coalesce(sum(s.quantity), 0), 2)
                   from public.inventory_stock s where s.warehouse_id = wh.id),
                (select to_char(coalesce(sum(s.quantity * it.cost), 0), 'FM999,999,990.00')
                   from public.inventory_stock s join it on it.id = s.item_id
                  where s.warehouse_id = wh.id),
                (select count(*) from public.inventory_movements im
                  where im.warehouse_id = wh.id),
                (select round(coalesce(-sum(mov.quantity), 0), 2) from mov
                  where mov.warehouse_id = wh.id and mov.tipo = 'sale'),
                (select round(coalesce(sum(mov.quantity), 0), 2) from mov
                  where mov.warehouse_id = wh.id and mov.tipo <> 'sale'))
  from wh, p

  union all
  -- 3 · Conteos físicos, y cuántas líneas coinciden con cada columna del JSON
  --     (dice si la parte de cafetería ya se cargó en alguna bodega).
  select 3, '3 CONTEOS', ses.code || ' · ' || ses.bodega,
         format('%s · congelado %s · cerrado %s · líneas %s, contadas %s, ajustadas %s'
                || ' · coinciden con JSON: cafetería %s, almacén %s, total %s%s',
                ses.status,
                coalesce(to_char(ses.frozen_at at time zone p.tz, 'DD/MM HH24:MI'), '-'),
                coalesce(to_char(ses.completed_at at time zone p.tz, 'DD/MM HH24:MI'), '-'),
                (select count(*) from public.physical_count_lines l
                  where l.session_id = ses.id),
                (select count(*) from public.physical_count_lines l
                  where l.session_id = ses.id and l.counted_quantity is not null),
                (select count(*) from public.physical_count_lines l
                  where l.session_id = ses.id and l.applied_adjustment_id is not null),
                (select count(*) from public.physical_count_lines l
                   join mt on mt.item_id = l.item_id
                  where l.session_id = ses.id and mt.caf > 0
                    and l.counted_quantity = mt.caf),
                (select count(*) from public.physical_count_lines l
                   join mt on mt.item_id = l.item_id
                  where l.session_id = ses.id and mt.alm > 0
                    and l.counted_quantity = mt.alm),
                (select count(*) from public.physical_count_lines l
                   join mt on mt.item_id = l.item_id
                  where l.session_id = ses.id and mt.total > 0
                    and l.counted_quantity = mt.total),
                case when ses.campania
                     then ' · CAMPAÑA 01-OCT: su ajuste lo reemplaza el JSON' else '' end)
  from ses, p

  union all
  select 3, '3 CONTEOS', p.pc_corte || ' vs columna almacén del JSON',
         (select format('%s diferencias%s', count(*),
                        coalesce(': ' || string_agg(it.name || ' (conteo ' || l.counted_quantity
                                 || ' / JSON ' || coalesce(mt.alm::text, 'no está') || ')', '; '), ''))
            from public.physical_count_lines l
            join corte k on k.id = l.session_id
            join it on it.id = l.item_id
            left join mt on mt.item_id = l.item_id
           where l.counted_quantity is not null
             and l.counted_quantity is distinct from coalesce(mt.alm, 0))
  from p

  union all
  -- 4 · ¿Hubo ventas el 01-oct alrededor del corte?
  select 4, '4 VENTAS 01-OCT', x.cual,
         format('%s movimientos, %s u', count(im.id), round(coalesce(-sum(im.quantity), 0), 2))
  from p
  cross join corte k
  cross join (values ('a) antes del corte'), ('b) después del corte, mismo día')) x(cual)
  left join public.inventory_movements im
    on im.business_id = p.b and im.movement_type = 'sale'
   and (im.created_at at time zone p.tz)::date = date '2026-10-01'
   and ((x.cual like 'a%' and im.created_at <= k.frozen_at)
     or (x.cual like 'b%' and im.created_at > k.frozen_at))
  group by x.cual

  union all
  select 4, '4 VENTAS 01-OCT', 'c) primera venta registrada en el negocio',
         coalesce(to_char(min(im.created_at) at time zone p.tz, 'DD/MM/YYYY HH24:MI'), 'ninguna')
  from p
  left join public.inventory_movements im
    on im.business_id = p.b and im.movement_type = 'sale'
  group by p.tz

  union all
  -- 5 · Qué se movió después del corte (lo que se va a descontar o sumar).
  select 5, '5 TRAS EL CORTE',
         mov.tipo || coalesce(' / ' || mov.reference_type, '') || coalesce(' / ' || mov.reason, ''),
         format('%s movimientos, %s u, %s ítems', count(*), round(sum(mov.quantity), 2),
                count(distinct mov.item_id))
  from mov
  group by mov.tipo, mov.reference_type, mov.reason

  union all
  -- 6 · Lo que impide aplicar (o merece aviso).
  select 6, '6 BLOQUEOS', 'conteos abiertos',
         coalesce(string_agg(ses.code || ' (' || ses.status || ')'
                             || case when ses.code = p.pc_abandonado
                                       and coalesce((ses.frozen_at at time zone p.tz)::date,
                                                    date '2026-10-01') = date '2026-10-01'
                                     then ' → el aplicar lo CANCELA' else ' ✗ BLOQUEA' end,
                             ', '), 'ninguno')
  from ses, p where ses.status in ('draft', 'in_progress')

  union all
  select 6, '6 BLOQUEOS', 'conteos completados DESPUÉS del 01-oct',
         coalesce(string_agg(ses.code || ' · ' || ses.bodega, ', '), 'ninguno')
  from ses, p
  where ses.status = 'completed'
    and (ses.frozen_at at time zone p.tz)::date > date '2026-10-01'

  union all
  select 6, '6 BLOQUEOS', 'transferencias sin cerrar', count(*)::text
  from public.stock_transfers t, p
  where t.business_id = p.b and t.status in ('sent', 'pending_approval')

  union all
  select 6, '6 AVISO', 'órdenes abiertas con consumo fuera de la principal',
         count(distinct z.reference_id)::text
  from (select im.reference_id
          from public.inventory_movements im
          join public.orders o on o.id = im.reference_id, p
         where im.business_id = p.b
           and im.reference_type = 'order' and im.movement_type = 'sale'
           and im.warehouse_id <> (select id from principal)
           and o.status in ('open', 'sent', 'served')
           and coalesce(o.status_ext::text, 'open') not in ('paid', 'void')
         group by im.reference_id, im.warehouse_id, im.item_id
        having sum(im.quantity) <> 0) z

  union all
  select 6, '6 AVISO', 'existencia en tránsito (__IN_TRANSIT__)',
         coalesce((select format('%s ítems, %s u', count(*), round(coalesce(sum(s.quantity), 0), 2))
                     from public.inventory_stock s
                    where s.warehouse_id in (select id from wh where transito)
                      and s.quantity <> 0), '0')

  union all
  -- 7 · Otras tablas que apuntan a una bodega que se va a apagar.
  select 7, '7 REFERENCIAS', c.table_name || '.' || c.column_name,
         x.n || ' filas apuntan a una bodega que no es la principal'
  from information_schema.columns c
  join information_schema.tables t
    on t.table_schema = c.table_schema and t.table_name = c.table_name
   and t.table_type = 'BASE TABLE'
  cross join lateral (
    select (xpath('/row/n/text()', query_to_xml(format(
             'select count(*) as n from public.%I where %I = any (%L::uuid[])',
             c.table_name, c.column_name,
             (select coalesce(array_agg(wh.id), '{}'::uuid[]) from wh
               where not wh.transito
                 and wh.id <> (select id from principal))::text),
           false, true, '')))[1]::text::int as n
  ) x
  where c.table_schema = 'public' and c.data_type = 'uuid'
    and c.column_name like '%warehouse%'
    and c.table_name not in ('warehouses', 'inventory_stock', 'inventory_movements',
                             'physical_count_sessions', 'physical_count_lines')
    and x.n > 0

  union all
  -- 8 · Cruce del conteo con el sistema y vista previa del resultado.
  select 8, '8 CRUCE', 'a) códigos del conteo (cafetería)',
         format('%s líneas · encontradas %s · no existen %s · ambiguas %s',
                count(*), count(mt.item_id),
                count(*) filter (where mt.n_sku = 0 and mt.n_bc = 0),
                count(*) filter (where mt.item_id is null
                                   and not (mt.n_sku = 0 and mt.n_bc = 0)))
  from mt

  union all
  select 8, '8 CRUCE', 'b) no existen en el sistema',
         coalesce(string_agg(mt.codigo || ' ' || mt.descripcion, '; '), 'ninguno')
  from mt where mt.n_sku = 0 and mt.n_bc = 0

  union all
  select 8, '8 CRUCE', 'c) ambiguos (más de un insumo con ese código)',
         coalesce(string_agg(mt.codigo || ' ' || mt.descripcion
                             || ' (sku ' || mt.n_sku || ', barras ' || mt.n_bc || ')', '; '),
                  'ninguno')
  from mt where mt.item_id is null and not (mt.n_sku = 0 and mt.n_bc = 0)

  union all
  select 8, '8 VISTA PREVIA', 'd) objetivo = contado + lo movido tras el corte',
         format('contado %s u · tras el corte %s u · objetivo %s u · hoy (todas las bodegas) %s u'
                || ' · ajuste neto %s u (+%s / %s) · valor del ajuste RD$%s',
                round(sum(obj.total), 2), round(sum(obj.post), 2),
                round(sum(obj.total + obj.post), 2), round(sum(obj.actual), 2),
                round(sum(obj.total + obj.post - obj.actual), 2),
                round(sum(greatest(obj.total + obj.post - obj.actual, 0)), 2),
                round(sum(least(obj.total + obj.post - obj.actual, 0)), 2),
                to_char(sum((obj.total + obj.post - obj.actual) * it.cost), 'FM999,999,990.00'))
  from obj join it on it.id = obj.item_id

  union all
  select 8, '8 VISTA PREVIA', 'e) quedarán en NEGATIVO (salió más de lo contado)',
         format('%s%s', count(*),
                coalesce(': ' || string_agg(obj.descripcion || ' (contado ' || trim_scale(obj.total)
                         || ', tras corte ' || trim_scale(obj.post) || ')', '; '), ''))
  from obj where obj.total + obj.post < 0

  union all
  select 8, '8 VISTA PREVIA', 'f) NO contados con existencia en otras bodegas (solo se mudan)',
         format('%s ítems, %s u', count(distinct st.item_id), round(coalesce(sum(st.q), 0), 2))
  from st
  where st.warehouse_id <> (select id from principal) and st.q <> 0
    and st.item_id not in (select mt.item_id from mt where mt.item_id is not null)

  union all
  select 8, '8 VISTA PREVIA', 'g) NO contados con existencia ≠ 0 (quedan con su número)',
         format('%s ítems', count(*))
  from (select st.item_id from st
         where st.item_id not in (select mt.item_id from mt where mt.item_id is not null)
         group by st.item_id having sum(st.q) <> 0) z
)
select orden, seccion, item, detalle
from filas
order by orden, seccion, item;
