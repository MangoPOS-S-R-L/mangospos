-- =============================================================================
-- LA PENDA EXPRESS · ACTIVAR INVENTARIO — PASO 0: el estado de HOY (12-oct)
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta (Studio solo muestra el último resultado).
--
-- La última vez que se midió Penda fue el 23-sep. Antes de cerrar conteos o
-- encender nada hay que saber qué cambió desde entonces:
--   E1  TODOS los conteos desde agosto (abiertos y cerrados): ¿cuáles son
--       «los últimos»? ¿se hizo uno nuevo en octubre?
--   E2  almacenes: ¿se crearon Cocina / FoodShop / Bar?
--   E3  qué se movió desde el congelado del conteo abierto más viejo
--   E4  recetas: cuántas, cuántas siguen «SIN revisar por cocina»
--   E5  productos: cuántos descuentan hoy, cuántos se apagarían por auto-86
--   E6  cómo CIERRA el conteo en la BD viva (contado − stock vivo, o − snapshot)
--   E7  banderas, y si los scripts OP_3 / OP_7 ya se corrieron
--   E8  salud del stock: negativos, absurdos, valor por almacén
--
-- Las columnas opcionales se leen con to_jsonb(fila)->>'col' para que la
-- consulta no truene si una migración no está aplicada.
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),

ses as (
  select s.*, to_jsonb(s) as j
    from public.physical_count_sessions s, biz
   where s.business_id = biz.id
     and s.started_at >= '2026-08-01'
),
abiertas as (
  select min(coalesce((j->>'frozen_at')::timestamptz, started_at)) as desde
    from ses where status in ('draft','in_progress')
),

-- ── E1 · los conteos ────────────────────────────────────────────────────────
e1 as (
  select 1 as orden, 'E1 conteos' as seccion,
         s.code || ' · ' || upper(s.status) || ' → ' || coalesce(w.name,'(sin almacén)') as dato,
         concat_ws(' · ',
           'abierto ' || to_char(s.started_at, 'DD-Mon'),
           'congelado ' || coalesce(to_char((s.j->>'frozen_at')::timestamptz, 'DD-Mon'), '—'),
           'cerrado '   || coalesce(to_char((s.j->>'completed_at')::timestamptz, 'DD-Mon HH24:MI'), '—'),
           count(l.id) || ' líneas',
           count(l.id) filter (where l.counted_quantity is not null) || ' contadas',
           count(l.id) filter (where l.counted_quantity is null) || ' en blanco',
           -- cuándo se tecleó de verdad: el congelado y el conteo pueden ser
           -- de fechas distintas
           'tecleado ' || coalesce(to_char(min(l.updated_at)
                               filter (where l.counted_quantity is not null)
                               at time zone 'America/Santo_Domingo', 'DD-Mon HH24:MI'), '—')
             || ' → ' || coalesce(to_char(max(l.updated_at)
                               filter (where l.counted_quantity is not null)
                               at time zone 'America/Santo_Domingo', 'DD-Mon HH24:MI'), '—'),
           nullif(trim(coalesce(s.notes,'')), '')
         ) as valor,
         s.started_at as ord2
    from ses s
    left join public.warehouses w on w.id = s.warehouse_id
    left join public.physical_count_lines l on l.session_id = s.id
   group by s.id, s.code, s.status, s.j, s.started_at, s.notes, w.name
),

-- ── E2 · almacenes ──────────────────────────────────────────────────────────
e2 as (
  select 2, 'E2 almacenes', w.name,
         concat_ws(' · ',
           coalesce(to_jsonb(w)->>'warehouse_type', 'sin tipo'),
           case when w.is_main then 'PRINCIPAL' end,
           case when not coalesce(w.is_active, true) then 'INACTIVO' end,
           case when to_jsonb(w)->>'production_area_id' is not null
                then 'área: ' || coalesce(pa.name, '?') end,
           case when coalesce((to_jsonb(w)->>'shows_in_pos')::boolean, false)
                then 'SALE EN POS' end,
           (select count(*) || ' con stock ≠ 0'
              from public.inventory_stock st
             where st.warehouse_id = w.id and st.quantity <> 0)
         ),
         w.created_at
    from public.warehouses w
    cross join biz
    left join public.print_areas pa
           on pa.id = (to_jsonb(w)->>'production_area_id')::uuid
   where w.business_id = biz.id
),

-- ── E3 · movido desde el congelado ──────────────────────────────────────────
--   Si no hay conteos abiertos, sale UNA fila diciéndolo.
e3 as (
  select 3, 'E3 movido desde ' || coalesce(to_char(a.desde, 'DD-Mon'), '(sin conteo abierto)'),
         coalesce(im.movement_type::text, '—'),
         case when im.movement_type is null then 'no hay conteo abierto: nada que reaplicar'
         else concat_ws(' · ',
           count(*) || ' movimientos',
           count(distinct im.item_id) || ' insumos',
           'neto ' || round(sum(im.quantity), 2),
           'último ' || to_char(max(im.created_at), 'DD-Mon'))
         end,
         null::timestamptz
    from abiertas a
    cross join biz
    left join public.inventory_movements im
           on im.business_id = biz.id and im.created_at >= a.desde
   group by a.desde, im.movement_type
),

-- ── E4 · recetas ────────────────────────────────────────────────────────────
rec as (
  select r.id, r.menu_item_id, m.is_active, m.is_inventory_tracked,
         coalesce(r.instructions,'') ilike '%SIN revisar%' as sin_revisar,
         coalesce(m.description,'') ilike '%INACTIVO y en precio 0%' as creado_para_receta
    from public.recipes r
    join public.menu_items m on m.id = r.menu_item_id, biz
   where m.business_id = biz.id
),
e4 as (
  select 4, 'E4 recetas', x.dato, x.valor, null::timestamptz from (
    select 'total' as dato,
           count(*) || ' recetas · '
           || (select count(*) from public.recipe_ingredients ri
                where ri.recipe_id in (select id from rec)) || ' ingredientes' as valor
      from rec
    union all
    select 'encendidas (descuentan hoy)',
           count(*) filter (where coalesce(is_inventory_tracked,false))::text
           || ' de ' || count(*) from rec
    union all
    select 'marca «SIN revisar por cocina»',
           count(*) filter (where sin_revisar)::text || ' de ' || count(*) from rec
    union all
    select 'producto INACTIVO',
           count(*) filter (where not coalesce(is_active,true))::text
           || ' (de ellos creados en precio 0 para la receta: '
           || count(*) filter (where not coalesce(is_active,true) and creado_para_receta) || ')'
      from rec
    union all
    -- Recetas que el auto-86 apagaría al encender: algún ingrediente en <= 0
    -- sumando TODOS los almacenes (cota optimista).
    select 'se apagarían al encender (algún insumo en 0)',
           count(*)::text || ' de las que están activas'
      from rec
     where coalesce(rec.is_active,true)
       and exists (
         select 1 from public.recipe_ingredients ri
          where ri.recipe_id = rec.id and ri.inventory_item_id is not null
            and coalesce((select sum(st.quantity) from public.inventory_stock st
                           where st.item_id = ri.inventory_item_id), 0) <= 0)
  ) x
),

-- ── E5 · productos ──────────────────────────────────────────────────────────
mi as (
  select m.*, to_jsonb(m) as j,
         exists (select 1 from public.recipes r where r.menu_item_id = m.id) as con_receta
    from public.menu_items m, biz
   where m.business_id = biz.id
),
e5 as (
  select 5, 'E5 productos', x.dato, x.valor, null::timestamptz from (
    select 'activos' as dato, count(*) filter (where coalesce(is_active,true))::text as valor from mi
    union all
    select 'descuentan HOY (tracked)',
           count(*) filter (where coalesce(is_inventory_tracked,false) and coalesce(is_active,true))::text
           || ' · vínculo directo ' ||
           count(*) filter (where coalesce(is_inventory_tracked,false) and coalesce(is_active,true)
                              and not con_receta and inventory_item_id is not null)
           || ' · con receta ' ||
           count(*) filter (where coalesce(is_inventory_tracked,false) and coalesce(is_active,true)
                              and con_receta)
           || ' · tracked SIN nada que descontar ' ||
           count(*) filter (where coalesce(is_inventory_tracked,false) and coalesce(is_active,true)
                              and not con_receta and inventory_item_id is null)
      from mi
    union all
    select 'allow_negative_sale entre los tracked',
           count(*) filter (where coalesce(is_inventory_tracked,false)
                              and coalesce((j->>'allow_negative_sale')::boolean,false))::text
           || ' sí · ' ||
           count(*) filter (where coalesce(is_inventory_tracked,false)
                              and not coalesce((j->>'allow_negative_sale')::boolean,false))
           || ' no'
      from mi
    union all
    select 'apagados por auto-86 AHORA',
           count(*) filter (where coalesce((j->>'auto_disabled')::boolean,false)
                              and not coalesce(is_active,true))::text
      from mi
    union all
    -- Vendidos en los últimos 14 días que NO descuentan nada: el hueco que
    -- queda abierto aunque se cierre el conteo.
    select 'vendidos 14 días SIN descontar',
           count(distinct oi.product_id)::text || ' productos · '
           || coalesce(sum(coalesce(oi.qty, oi.quantity::numeric, 0)), 0) || ' unidades'
      from public.order_items oi
      join mi on mi.id = oi.product_id
     where oi.created_at >= now() - interval '14 days'
       and oi.status <> 'void'
       and not (coalesce(mi.is_inventory_tracked,false)
                and (mi.con_receta or mi.inventory_item_id is not null))
  ) x
),

-- ── E6 · cómo cierra el conteo ──────────────────────────────────────────────
e6 as (
  select 6, 'E6 CÓMO CIERRA el conteo',
         case
           when src is null then 'la función NO existe'
           when src ~* 'counted_quantity\s*-\s*v_current' then
             'contado − STOCK VIVO → el stock queda IGUAL a lo contado'
           when src ~* 'counted[_a-z]*\s*-\s*[a-z_.]*snapshot' then
             'contado − SNAPSHOT → SUMA la diferencia'
           else 'no concluyente — leer la línea de al lado'
         end,
         coalesce(regexp_replace(
           substring(src from '(?i)v_(?:applied|variance)\s*:=\s*[^;]+;'), '\s+', ' ', 'g'),
           '(sin línea de ajuste)'),
         null::timestamptz
    from (select 1) d
    left join lateral (
      select pg_get_functiondef(p.oid) as src
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_physical_count_complete'
       limit 1) f on true
),

-- ── E7 · banderas ───────────────────────────────────────────────────────────
e7 as (
  select 7, 'E7 banderas', x.dato, x.valor, null::timestamptz from (
    select 'inventory_mode' as dato,
           coalesce((select bs.inventory_mode::text from public.business_settings bs, biz
                      where bs.business_id = biz.id limit 1), '(sin fila)') as valor
    union all
    select 'warehouse_sections_enabled',
           coalesce((select to_jsonb(bs)->>'warehouse_sections_enabled'
                       from public.business_settings bs, biz
                      where bs.business_id = biz.id limit 1), 'sin columna / sin fila')
    union all
    select 'fn_inventory_record_movement exige sesión',
           case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname='public' and p.proname='fn_inventory_record_movement'
                                and pg_get_functiondef(p.oid) ~* 'auth\.uid\(\)')
                then 'SÍ → desde el SQL Editor hay que insertar el movimiento directo'
                else 'no' end
    union all
    select 'tabla _penda_op3_backup (OP_3 corrido)',
           case when to_regclass('public._penda_op3_backup') is null then 'no existe'
                else 'EXISTE' end
    union all
    select 'tabla _penda_rollforward (OP_7a corrido)',
           case when to_regclass('public._penda_rollforward') is null then 'no existe'
                else 'EXISTE' end
    union all
    select 'modifier_ingredients',
           case when to_regclass('public.modifier_ingredients') is null then 'no existe'
                else 'existe' end
    union all
    select 'consumo con candado (20261010_0010)',
           case when to_regprocedure('public.consume_inventory_from_order_unlocked(uuid)') is null
                then 'NO' else 'sí' end
  ) x
),

-- ── E8 · salud del stock ────────────────────────────────────────────────────
st as (
  select w.name as almacen, st.item_id, st.quantity, coalesce(i.cost,0) as cost
    from public.inventory_stock st
    join public.warehouses w on w.id = st.warehouse_id
    join public.inventory_items i on i.id = st.item_id, biz
   where w.business_id = biz.id
     and coalesce(i.is_active, true)
),
e8 as (
  select 8, 'E8 stock', almacen,
         concat_ws(' · ',
           count(*) filter (where quantity > 0) || ' insumos > 0',
           count(*) filter (where quantity < 0) || ' NEGATIVOS',
           count(*) filter (where quantity > 100000) || ' ABSURDOS (>100k)',
           'valor ' || to_char(sum(quantity * cost) filter (where quantity > 0 and quantity <= 100000),
                               'FM999,999,999.00')),
         null::timestamptz
    from st group by almacen
)

select seccion, dato, valor from (
  select * from e1 union all select * from e2 union all select * from e3
  union all select * from e4 union all select * from e5 union all select * from e6
  union all select * from e7 union all select * from e8
) todo
order by orden, ord2 nulls last, dato;
