-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 1: los dos bloqueadores
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta.
--
-- El PASO 0 destapó dos cosas que hay que resolver ANTES de tocar nada:
--
--   C1  UN AJUSTE DE 16,571,953,563.75 UNIDADES.
--       71 movimientos de tipo `adjustment` sobre 52 insumos suman dieciséis
--       mil millones. Eso no es inventario: es un dedo pegado en el teclado,
--       o una unidad mal convertida. Mientras esté ahí, el stock de esos
--       insumos es ficción y cualquier receta que los use descuenta basura.
--
--   C2  CÓMO CIERRA EL CONTEO, de verdad.
--       El PASO 0 no encontró la línea `v_variance := ...`, así que la
--       función existe pero está escrita de otra forma. Aquí se devuelve el
--       cuerpo numerado para leer a mano las líneas que tocan el stock.
--       De esto depende si hay que hacer rollforward de las 3 semanas.
--
--   C3  el reparto real del conteo: 874 líneas contadas en 5 sesiones que
--       TODAS apuntan al Almacén Principal, y cuántos insumos se contaron en
--       más de una (esos son los que se pisan al cerrar).
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
ses as (
  -- `physical_count_sessions` en prod NO tiene created_at: se lee por
  -- to_jsonb para que la consulta no truene si falta la columna.
  select s.id, s.code, s.notes,
         coalesce((to_jsonb(s)->>'frozen_at')::timestamptz,
                  (to_jsonb(s)->>'created_at')::timestamptz) as desde
    from public.physical_count_sessions s, biz
   where s.business_id = biz.id and s.status in ('draft','in_progress')
),
congelado as (select min(desde) as desde from ses),

-- ── C1 · los ajustes absurdos, uno por uno ──────────────────────────────────
c1 as (
  select 1 as orden,
         'C1 ajustes desde el congelado' as seccion,
         to_char(im.created_at at time zone 'America/Santo_Domingo','DD-Mon HH24:MI')
           || ' · ' || coalesce(i.name,'(insumo borrado)') as dato,
         concat_ws(' · ',
           'qty ' || trim(to_char(im.quantity, 'FM9999999999999990.00')),
           'unidad ' || coalesce(i.unit,'?'),
           'costo/u ' || coalesce(trim(to_char(im.cost_per_unit,'FM999990.00')),'—'),
           coalesce(nullif(im.notes,''), '(sin nota)'),
           coalesce(e.first_name || ' ' || e.last_name, '(sin empleado)')
         ) as valor
    from public.inventory_movements im
    cross join biz
    cross join congelado c
    left join public.inventory_items i on i.id = im.item_id
    left join public.employees e
           on e.user_id = im.created_by and e.business_id = biz.id
   where im.business_id = biz.id
     and im.created_at >= c.desde
     and im.movement_type = 'adjustment'
     and abs(im.quantity) >= 1000            -- lo normal no llega a mil
   order by abs(im.quantity) desc
   limit 25
),

-- ── C2 · el cuerpo de la función, numerado ──────────────────────────────────
--   Solo las líneas que TOCAN el stock. Es lo que decide si hay rollforward.
c2 as (
  select 2, 'C2 fn_physical_count_complete',
         lpad(n::text, 3, '0'),
         regexp_replace(linea, '\s+', ' ', 'g')
    from (
      select row_number() over () as n, linea
        from (select pg_get_functiondef(p.oid) as src
                from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
               where n2.nspname='public' and p.proname='fn_physical_count_complete'
               limit 1) f,
             lateral regexp_split_to_table(f.src, E'\n') as linea
    ) z
   where linea ~* 'inventory_stock|inventory_movements|counted|variance|delta|'
                  '\mstock\M|quantity|insert into|update public'
),

-- ── C3 · el reparto del conteo ──────────────────────────────────────────────
c3 as (
  select 3, 'C3 reparto del conteo', dato, valor from (
    -- cuántos insumos se contaron en 2+ sesiones: esos se pisan al cerrar
    select 'insumos contados en 2+ sesiones' as dato,
           count(*)::text || ' de ' ||
           (select count(distinct l2.item_id)::text
              from public.physical_count_lines l2
              join ses s2 on s2.id = l2.session_id
             where l2.counted_quantity is not null) || ' únicos' as valor
      from (select l.item_id
              from public.physical_count_lines l
              join ses s on s.id = l.session_id
             where l.counted_quantity is not null
             group by l.item_id having count(distinct l.session_id) > 1) d
    union all
    -- insumos CON stock hoy que ninguna sesión contó: al cerrar conservan
    -- su número viejo. Es la "existencia fantasma".
    select 'con stock hoy que NADIE contó',
           count(*)::text || ' insumos · ' ||
           trim(to_char(coalesce(sum(st.quantity * i.cost),0),'FM999,999,999.00')) || ' al costo'
      from public.inventory_stock st
      join public.warehouses w on w.id = st.warehouse_id
      join public.inventory_items i on i.id = st.item_id
     cross join biz
     where w.business_id = biz.id and st.quantity > 0
       and not exists (select 1 from public.physical_count_lines l
                        join ses s on s.id = l.session_id
                       where l.item_id = st.item_id and l.counted_quantity is not null)
    union all
    -- productos con inventario ENCENDIDO: cargarles receta los hace
    -- descontar en el acto. No existe "cargar dormida" para estos.
    select 'productos encendidos SIN receta',
           count(*)::text || ' de ' ||
           (select count(*)::text from public.menu_items m2, biz
             where m2.business_id = biz.id and coalesce(m2.is_active,true)) || ' activos'
      from public.menu_items m, biz
     where m.business_id = biz.id and coalesce(m.is_active,true)
       and coalesce(m.is_inventory_tracked,false)
       and not exists (select 1 from public.recipes r where r.menu_item_id = m.id)
    union all
    -- de esos, cuántos tienen vínculo directo (esos SÍ descuentan hoy)
    select 'de esos, con vínculo directo (ya descuentan)',
           count(*)::text
      from public.menu_items m, biz
     where m.business_id = biz.id and coalesce(m.is_active,true)
       and coalesce(m.is_inventory_tracked,false)
       and m.inventory_item_id is not null
       and not exists (select 1 from public.recipes r where r.menu_item_id = m.id)
  ) x
)

select seccion, dato, valor from (
  select * from c1 union all select * from c2 union all select * from c3
) todo
order by orden, dato;
