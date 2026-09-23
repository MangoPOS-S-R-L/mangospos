-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 0: el estado de hoy
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta — el SQL Editor de Supabase solo muestra el
-- ÚLTIMO resultado, así que todo va en un mismo select.
--
-- Contesta las siete cosas que deciden el orden de la operación:
--   B1  qué almacenes existen ya (¿se creó «Bar» a mano?)
--   B2  las sesiones de conteo: a qué almacén apuntan y desde cuándo
--   B3  qué se movió desde el congelado (compras, ventas, mermas, ajustes)
--   B4  cuántas recetas hay vivas hoy
--   B5  cuántos productos tienen el inventario encendido  ← el auto-86
--   B6  cómo CIERRA el conteo en prod: ¿deja lo contado, o suma la diferencia?
--   B7  banderas y columnas opcionales que la BD puede no tener
--
-- La fila B6 es la que manda. Si el cierre DEJA el stock en lo contado, hay que
-- hacer rollforward (sumar compras y restar ventas desde el congelado) o se
-- pierden las tres semanas. Si SUMA la diferencia, no hay que tocar nada —y
-- cerrar dos sesiones del mismo insumo restaría dos veces.
--
-- Las columnas opcionales se leen con to_jsonb(fila)->>'columna': así la
-- consulta no truena si la migración que las trae no está aplicada.
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),

ses as (
  select s.*, to_jsonb(s) as j
    from public.physical_count_sessions s, biz
   where s.business_id = biz.id
     and s.status in ('draft','in_progress')
),
congelado as (
  select min(coalesce((j->>'frozen_at')::timestamptz,
                      (j->>'created_at')::timestamptz)) as desde
    from ses
),

-- ── B1 ──────────────────────────────────────────────────────────────────────
b1 as (
  select 1 as orden, 'B1 almacenes' as seccion,
         w.name as dato,
         concat_ws(' · ',
           coalesce(to_jsonb(w)->>'warehouse_type', 'sin tipo'),
           case when w.is_main then 'PRINCIPAL' else null end,
           case when coalesce(w.is_active,true) then null else 'INACTIVO' end,
           case when to_jsonb(w)->>'production_area_id' is not null
                then 'área: ' || coalesce(pa.name,'?') else null end,
           case when coalesce((to_jsonb(w)->>'shows_in_pos')::boolean, false)
                then 'sale en POS' else null end,
           (select count(*)::text || ' insumos con fila'
              from public.inventory_stock st where st.warehouse_id = w.id)
         ) as valor
    from public.warehouses w
    cross join biz
    left join public.print_areas pa
           on pa.id = (to_jsonb(w)->>'production_area_id')::uuid
   where w.business_id = biz.id
),

-- ── B2 ──────────────────────────────────────────────────────────────────────
b2 as (
  select 2, 'B2 conteos abiertos',
         s.code || ' → ' || coalesce(w.name,'(sin almacén)'),
         concat_ws(' · ',
           s.status,
           count(l.*) || ' líneas',
           count(l.*) filter (where l.counted_quantity is not null) || ' contadas',
           count(l.*) filter (where l.counted_quantity is null) || ' EN BLANCO',
           'congelado ' || to_char(coalesce((s.j->>'frozen_at')::timestamptz,
                                            (s.j->>'created_at')::timestamptz),
                                   'DD-Mon'),
           coalesce(s.notes,'')
         )
    from ses s
    left join public.warehouses w on w.id = s.warehouse_id
    left join public.physical_count_lines l on l.session_id = s.id
   group by s.code, w.name, s.status, s.j, s.notes
),

-- ── B3 ──────────────────────────────────────────────────────────────────────
--   Lo que el sistema YA posteó desde el congelado. Si el cierre deja el stock
--   en lo contado, esto es exactamente lo que hay que volver a aplicar.
b3 as (
  select 3, 'B3 movido desde el congelado',
         im.movement_type::text,
         concat_ws(' · ',
           count(*) || ' movimientos',
           count(distinct im.item_id) || ' insumos',
           'neto ' || round(sum(im.quantity), 2),
           'costo ' || to_char(coalesce(sum(im.quantity * im.cost_per_unit),0),
                               'FM999,999,999.00')
         )
    from public.inventory_movements im, biz, congelado c
   where im.business_id = biz.id
     and im.created_at >= c.desde
   group by im.movement_type
),

-- ── B4 · B5 ─────────────────────────────────────────────────────────────────
b4 as (
  select 4, 'B4 recetas vivas',
         'recetas / ingredientes',
         (select count(distinct r.id)::text from public.recipes r
            join public.menu_items m on m.id = r.menu_item_id, biz
           where m.business_id = biz.id)
         || ' / ' ||
         (select count(*)::text from public.recipe_ingredients ri
            join public.recipes r on r.id = ri.recipe_id
            join public.menu_items m on m.id = r.menu_item_id, biz
           where m.business_id = biz.id)
),
b5 as (
  select 5, 'B5 inventario encendido',
         'productos con is_inventory_tracked',
         count(*) filter (where coalesce(m.is_inventory_tracked,false))::text
         || ' de ' || count(*)::text || ' activos'
         || ' · ' || count(*) filter (where coalesce(m.is_inventory_tracked,false)
                                        and exists (select 1 from public.recipes r
                                                     where r.menu_item_id = m.id))::text
         || ' de ellos CON receta'
    from public.menu_items m, biz
   where m.business_id = biz.id and coalesce(m.is_active,true)
),

-- ── B6 ──────────────────────────────────────────────────────────────────────
--   Se lee el CUERPO de la función en la BD viva, no lo que diga el repo.
b6 as (
  select 6, 'B6 CÓMO CIERRA el conteo',
         case
           when src is null then 'la función NO existe'
           when src ~* 'counted[_a-z]*\s*-\s*[a-z_]*snapshot' then
             'contado − SNAPSHOT → SUMA la diferencia (no hace falta rollforward; '
             || 'cerrar dos sesiones del mismo insumo RESTA DOS VECES)'
           when src ~* 'counted[_a-z]*\s*-\s*[a-z_]*(stock|quantity)' then
             'contado − STOCK → DEJA el stock en lo contado '
             || '(ROLLFORWARD OBLIGATORIO: se pierden las semanas desde el congelado)'
           else 'no concluyente — leer la línea de abajo a mano'
         end,
         coalesce(regexp_replace(
           substring(src from '(?i)v_variance\s*:=\s*[^;]+;'), '\s+', ' ', 'g'),
           '(sin línea de varianza)')
    -- el left join lateral es a proposito: si la funcion no existe, la fila
    -- B6 tiene que SALIR diciendolo, no desaparecer del reporte.
    from (select 1) d
    left join lateral (
           select pg_get_functiondef(p.oid) as src
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'fn_physical_count_complete'
            limit 1) f on true
),

-- ── B7 ──────────────────────────────────────────────────────────────────────
b7 as (
  select 7, 'B7 banderas y columnas', dato, valor from (
    select 'warehouse_sections_enabled' as dato,
           coalesce((select (to_jsonb(bs)->>'warehouse_sections_enabled')
                       from public.business_settings bs, biz
                      where bs.business_id = biz.id limit 1),
                    'sin columna / sin fila') as valor
    union all
    select 'warehouses.warehouse_type',
           case when exists (select 1 from information_schema.columns
                              where table_schema='public' and table_name='warehouses'
                                and column_name='warehouse_type')
                then 'SÍ existe' else 'NO existe (mig de secciones sin aplicar)' end
    union all
    select 'inventory_items.conversion_factor',
           case when exists (select 1 from information_schema.columns
                              where table_schema='public' and table_name='inventory_items'
                                and column_name='conversion_factor')
                then 'SÍ existe (20260915_0001 aplicada)'
                else 'NO existe → los cruces de unidad no se pueden convertir' end
    union all
    select 'áreas de impresión',
           coalesce((select string_agg(pa.name, ' · ' order by pa.name)
                       from public.print_areas pa, biz where pa.business_id = biz.id),
                    '(ninguna)')
    union all
    select 'insumos activos',
           (select count(*)::text from public.inventory_items i, biz
             where i.business_id = biz.id and coalesce(i.is_active,true))
             || ' · con stock > 0: ' ||
           (select count(distinct st.item_id)::text
              from public.inventory_stock st
              join public.warehouses w on w.id = st.warehouse_id, biz
             where w.business_id = biz.id and st.quantity > 0)
  ) x
)

select seccion, dato, valor from (
  select * from b1 union all select * from b2 union all select * from b3
  union all select * from b4 union all select * from b5
  union all select * from b6 union all select * from b7
) todo
order by orden, dato;
