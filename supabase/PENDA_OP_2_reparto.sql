-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 2: el reparto, simulado
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta. No escribe nada.
--
-- LO QUE YA SABEMOS (PASO 1):
--
--   * El cierre DEJA el stock en lo contado. La línea 055 es
--         v_applied := v_line.counted_quantity - v_current;
--     contra el stock VIVO (línea 042-044). O sea: final = contado.
--     → ROLLFORWARD OBLIGATORIO de los 21 días desde el 1-sep.
--     → Y si dos sesiones cuentan el mismo insumo contra la MISMA bodega,
--       NO se suman: gana la última que cierre. Las otras se pierden.
--
--   * 202 de 661 insumos se contaron en 2+ sesiones. Con las 5 sesiones
--     apuntando al Almacén Principal, cerrar así pierde 202 conteos.
--
--   * El ajuste absurdo es UNA sola fila: CARIBAS PLATANITOS AJO 110G,
--     11-sep 17:51, 16,571,952,675 unidades, GLORIBEL B. Los otros 70
--     ajustes suman 889 entre todos.
--
-- ESTO CONTESTA LO QUE FALTA PARA ESCRIBIR EL REPARTO:
--   D1  CARIBAS: ¿dónde está ese stock y lo contó alguien?
--       (si está en el conteo, el cierre lo arregla solo)
--   D2  los 202 insumos contados dos veces, con qué cantidad y en qué sesión
--   D3  cómo quedaría cada almacén si se reparte y se cierra
--   D4  los 392 fantasma más caros (RD$2,969,225.90 en total)
--   D5  por dónde postea el cierre (para escribir el rollforward igual)
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
ses as (
  select s.id, s.code, coalesce(s.notes, s.code) as nombre,
         (to_jsonb(s)->>'frozen_at')::timestamptz as desde,
         -- EL MAPEO ACORDADO: cada sesión a su almacén.
         case s.code
           when 'PC-2026-000002' then 'Almacen Principal'
           when 'PC-2026-000003' then 'Cocina'
           when 'PC-2026-000004' then 'FoodShop'
           when 'PC-2026-000005' then 'FoodShop'
           when 'PC-2026-000006' then 'Bar'
         end as destino
    from public.physical_count_sessions s, biz
   where s.business_id = biz.id and s.status in ('draft','in_progress')
),
lin as (
  select l.item_id, l.counted_quantity as qty, s.code, s.nombre, s.destino
    from public.physical_count_lines l
    join ses s on s.id = l.session_id
   where l.counted_quantity is not null
),

-- ── D1 · CARIBAS ────────────────────────────────────────────────────────────
d1 as (
  select 1 as orden, 'D1 CARIBAS PLATANITOS' as seccion, dato, valor from (
    select 'stock hoy · ' || w.name as dato,
           trim(to_char(st.quantity,'FM9999999999999990.00')) as valor
      from public.inventory_stock st
      join public.warehouses w on w.id = st.warehouse_id
      join public.inventory_items i on i.id = st.item_id
     cross join biz
     where w.business_id = biz.id and i.name ilike '%CARIBAS%PLATANITO%'
    union all
    select '¿lo contó alguien?',
           coalesce((select string_agg(l.nombre || ' = ' || l.qty, ' · ')
                       from lin l
                       join public.inventory_items i on i.id = l.item_id
                      where i.name ilike '%CARIBAS%PLATANITO%'),
                    'NADIE — el cierre NO lo arregla, hay que ajustarlo a mano')
  ) x
),

-- ── D2 · los contados dos veces ─────────────────────────────────────────────
d2 as (
  select 2, 'D2 contado en 2+ sesiones',
         i.name,
         string_agg(l.nombre || ' → ' || l.destino || ' = ' ||
                    trim(to_char(l.qty,'FM999990.00')), '  |  ' order by l.nombre)
         || '   ⇒ ' ||
         case when count(*) > count(distinct l.destino)
              then 'CHOCAN: dos sesiones al mismo almacén, gana la última'
              else 'almacenes distintos: OK, cada uno se queda con lo suyo' end
    from lin l
    join public.inventory_items i on i.id = l.item_id
   group by i.name
  having count(*) > 1
   order by (count(*) > count(distinct l.destino)) desc, i.name
   limit 30
),

-- ── D3 · cómo quedaría cada almacén ─────────────────────────────────────────
--   Ojo: para los que chocan en el mismo almacén se toma el MÁXIMO, que es
--   lo más parecido a "gana el último" sin saber el orden de cierre.
d3 as (
  select 3, 'D3 si se reparte y se cierra', q.destino,
         count(distinct q.item_id)::text || ' insumos · ' ||
         trim(to_char(sum(q.qty_final * coalesce(i.cost,0)),'FM999,999,999.00')) || ' al costo'
    -- NO se vuelve a unir con `lin`: un insumo contado dos veces en el mismo
    -- destino traeria dos filas y el costo saldria doble. `q` ya esta colapsado.
    from (select item_id, destino, max(qty) as qty_final
            from lin group by item_id, destino) q
    join public.inventory_items i on i.id = q.item_id
   group by q.destino
),

-- ── D4 · los fantasma más caros ─────────────────────────────────────────────
d4 as (
  select 4, 'D4 fantasma (nadie lo contó)',
         i.name,
         trim(to_char(st.quantity,'FM9999999999999990.00')) || ' ' || coalesce(i.unit,'?') ||
         ' · ' || trim(to_char(st.quantity * i.cost,'FM9999999999999990.00')) || ' al costo' ||
         ' · ' || w.name
    from public.inventory_stock st
    join public.warehouses w on w.id = st.warehouse_id
    join public.inventory_items i on i.id = st.item_id
   cross join biz
   where w.business_id = biz.id and st.quantity > 0
     and not exists (select 1 from lin l where l.item_id = st.item_id)
   order by st.quantity * i.cost desc nulls last
   limit 20
),

-- ── D5 · por dónde postea el cierre ─────────────────────────────────────────
d5 as (
  select 5, 'D5 cómo postea el cierre',
         lpad(n::text,3,'0'),
         regexp_replace(linea,'\s+',' ','g')
    from (
      select row_number() over () as n, linea
        from (select pg_get_functiondef(p.oid) as src
                from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
               where n2.nspname='public' and p.proname='fn_physical_count_complete'
               limit 1) f,
             lateral regexp_split_to_table(f.src, E'\n') as linea
    ) z
   where linea ~* 'perform|select .*fn_|p_[a-z_]+ *=>|movement_type'
)

select seccion, dato, valor from (
  select * from d1 union all select * from d2 union all select * from d3
  union all select * from d4 union all select * from d5
) todo
order by orden, dato;
